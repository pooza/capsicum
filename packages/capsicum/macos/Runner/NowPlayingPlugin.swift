import CryptoKit
import FlutterMacOS
import Foundation

/// ミュージック.app（Apple Music）の「現在再生中の曲」を AppleScript 経由で取得し、
/// Dart 側 AppleMusicNowPlayingProvider (#668) に返すプラグイン。
///
/// チャンネル名 `capsicum/now_playing` / メソッド `getNowPlaying` は iOS / Windows
/// SMTC (#484) と揃える（OS ネイティブ pull の共通入口）。
///
/// **App Sandbox 下の TCC「オートメーション」許可（#668、build 109-115 の実機 Sentry で実証）:**
/// - `AEDeterminePermissionToAutomateTarget` は記述子が bundleId でも PID でも、
///   thread を問わず **procNotFound(-600)** になり使えない（112/114/115）。
///   （非 sandbox の swiftc 検証では noErr だが、製品は sandbox なので別挙動。）
/// - 一方、**名前指定の `tell application "Music"` はメインスレッドなら解決する**
///   （109/110 で曲読み取りまで到達）。バックグラウンドだと解決自体が -600。
/// - よって **メインスレッドで名前指定 AppleScript を、try で握り潰さず実行**する。
///   最初のイベント `player state` で TCC が発火し、許可なら続行、未決/拒否は
///   executeAndReturnError の errorNumber（-1744/-1743）に表面化する。許可未決の
///   初回送信はプロンプトを誘発し、応答後の再押下で取得できる（automation_pending
///   を compose が「許可して再試行」の案内に変換する）。
///
/// 失敗種別は `__nowPlayingError`（automation_denied / automation_pending / no_track /
/// script_error + __code）で返す。実曲は title/artist を持つマップ。ジャケットが
/// 取れた回は、書き出した一時ファイルのパスを `artworkPath` に添える (#1273)。
/// 書き出さなかった回は、理由を `artworkSkipped` に添える (#1283)。値は
/// `no_artwork` / `unsupported_format` / `too_large` / `write_failed` のどれか
/// （Dart 側の `kNowPlayingArtworkSkipReasons` と揃える）。
final class NowPlayingPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "capsicum/now_playing",
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getNowPlaying":
        // メインスレッドで実行（名前指定の対象解決が sandbox 下でメイン必須）。
        result(currentItemMap())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// ミュージック.app の現在の曲を title / artist / albumTitle のマップにする。
  /// `application "Music" is running` を tell の外で判定し、未起動のミュージックを
  /// 副作用で起動しない。**try で包まない**ことで TCC 拒否/応答待ちを表面化させる。
  ///
  /// ジャケット（アートワーク）も一緒に取る (#1273)。`raw data of artwork 1` は
  /// ストリーミングの曲（`shared track`）でも画像のバイト列を返す（2026-10-12 実測・
  /// 600x600 の JPEG）。⚠ **こちらだけは try で包む** —— アートワークの無い曲は
  /// ここでエラーになるが、曲名までは取れているので文字情報を巻き込まない。
  /// TCC の拒否 / 応答待ちは手前の `player state` で先に表面化する。
  private static func currentItemMap() -> [String: Any]? {
    let source = """
      if application "Music" is running then
        tell application "Music"
          if player state is stopped then return {}
          set trackInfo to {name of current track, artist of current track, album of current track}
          try
            set end of trackInfo to raw data of artwork 1 of current track
          end try
          return trackInfo
        end tell
      else
        return {}
      end if
      """
    var errorInfo: NSDictionary?
    guard
      let descriptor = NSAppleScript(source: source)?
        .executeAndReturnError(&errorInfo)
    else {
      // 実行失敗。-1743=TCC 拒否 / -1744=許可応答待ち は許可案内へ、それ以外
      // （-1728「現在トラックなし」等）は観測用に code を添えて返す。
      let code = (errorInfo?[NSAppleScript.errorNumber] as? Int) ?? 0
      switch code {
      case -1743:
        return ["__nowPlayingError": "automation_denied", "__code": code]
      case -1744:
        return ["__nowPlayingError": "automation_pending", "__code": code]
      default:
        return ["__nowPlayingError": "script_error", "__code": code]
      }
    }
    // 空 {} は 0 要素（未起動 / 停止中）。曲があれば {name, artist, album} の 3 要素。
    let items = descriptor.numberOfItems
    guard items >= 3 else {
      return ["__nowPlayingError": "no_track"]
    }
    var map: [String: Any] = [:]
    // NSAppleEventDescriptor のリストは 1 始まり。
    if let title = descriptor.atIndex(1)?.stringValue, !title.isEmpty {
      map["title"] = title
    }
    if let artist = descriptor.atIndex(2)?.stringValue, !artist.isEmpty {
      map["artist"] = artist
    }
    if let album = descriptor.atIndex(3)?.stringValue, !album.isEmpty {
      map["albumTitle"] = album
    }
    if map["title"] == nil && map["artist"] == nil {
      return ["__nowPlayingError": "no_track"]
    }
    // ⚠ 書き出さなかった理由も返す (#1283)。返さないと Dart 側の breadcrumb は
    // どれも「源が絵を持っていない」に見え、「付かない」という報告を切り分け
    // られない。
    guard items >= 4, let data = descriptor.atIndex(4)?.data, !data.isEmpty else {
      map["artworkSkipped"] = "no_artwork"
      return map
    }
    switch writeArtwork(data) {
    case .written(let path):
      map["artworkPath"] = path
    case .skipped(let reason):
      map["artworkSkipped"] = reason
    }
    return map
  }

  private enum ArtworkResult {
    case written(String)
    case skipped(String)
  }

  /// Dart 側の `kNowPlayingArtworkMaxBytes` と同じ上限。超えるものは書き出さない。
  private static let artworkMaxBytes = 10 * 1024 * 1024

  /// これより古い書き出しは、次に書き出すときに消す (#1283)。
  ///
  /// ⚠ **「いまの絵以外を全部消す」にしない。**投稿フォームは添付したジャケットを
  /// 投稿するまでファイルのまま持つので、別の曲で押し直した瞬間に前の絵を消すと、
  /// 添付済みのほうが読めなくなる。1 日たったものだけを消す。
  private static let artworkRetention: TimeInterval = 24 * 60 * 60

  /// アートワークのバイト列を一時ファイルへ書き出し、そのパスを返す (#1273)。
  /// 書き出さなかった回は理由を返す（画像でない / 大きすぎる / 書けなかった）。
  ///
  /// Dart 側は `file://` として既存の添付の経路（`fetchNowPlayingArtwork`）へ流す。
  /// ⚠ **置き場所は中身のハッシュで決める。**投稿フォームは「同じジャケットを
  /// 2 枚添付しない」を URI の一致で見ているので、同じ絵は同じパスに、違う絵は
  /// 違うパスになる必要がある。押すたびに一時ファイルが増えることもない。
  /// ⚠ ファイル名は固定（そのまま投稿先のファイル名になる）。
  private static func writeArtwork(_ data: Data) -> ArtworkResult {
    guard data.count <= artworkMaxBytes else { return .skipped("too_large") }
    let ext: String
    if data.starts(with: [0xFF, 0xD8, 0xFF]) {
      ext = "jpg"
    } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
      ext = "png"
    } else {
      return .skipped("unsupported_format")
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let dir = tmp.appendingPathComponent("\(artworkDirPrefix)\(digest.prefix(16))")
    let file = dir.appendingPathComponent("nowplaying-artwork.\(ext)")
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try data.write(to: file, options: .atomic)
    } catch {
      // 書けなくても曲の文字情報は返す（ジャケットは上積み）。
      return .skipped("write_failed")
    }
    purgeStaleArtwork(in: tmp, keeping: dir)
    return .written(file.path)
  }

  private static let artworkDirPrefix = "nowplaying_native_"

  /// 古い書き出しを消す (#1283)。違うジャケットの曲で押すたびに 1 ディレクトリ
  /// 増えるので、放っておくとコンテナの一時領域に溜まり続ける。
  ///
  /// ⚠ 失敗は握る（掃除は上積みで、いまの書き出しの成否に関係しない）。
  private static func purgeStaleArtwork(in tmp: URL, keeping current: URL) {
    let manager = FileManager.default
    guard
      let entries = try? manager.contentsOfDirectory(
        at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let threshold = Date().addingTimeInterval(-artworkRetention)
    for entry in entries {
      guard entry.lastPathComponent.hasPrefix(artworkDirPrefix),
        entry.lastPathComponent != current.lastPathComponent,
        let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
        modified < threshold
      else { continue }
      try? manager.removeItem(at: entry)
    }
  }
}
