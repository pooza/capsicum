import AVFoundation
import CryptoKit
import Flutter
import Foundation
import MediaPlayer
import UIKit

/// Apple Music（ミュージック.app）の「現在再生中の曲」を MediaPlayer framework
/// 経由で取得し、Dart 側 AppleMusicNowPlayingProvider (#668) に返すプラグイン。
///
/// チャンネル名 `capsicum/now_playing` / メソッド `getNowPlaying` は Windows
/// SMTC (#484) と揃える（OS ネイティブ pull の共通入口）。
///
/// `MPMusicPlayerController.systemMusicPlayer` はミュージックアプリの再生状態を
/// 反映する **App Store 許可の公開 API**（private MediaRemote.framework は使わ
/// ない）。`nowPlayingItem` の読み取りはメディアライブラリ権限
/// （`NSAppleMusicUsageDescription`）を要するため、初回取得時に
/// `requestAuthorization` でダイアログを出す。拒否・未再生はいずれも nil を返し、
/// Dart 側 resolver が「再生中の曲がありません」へフォールバックする。
///
/// ジャケットも取る (#1275)。返し方は macOS（#1273）と同じで、一時ファイルへ
/// 書き出したパスを `artworkPath` に、書き出さなかった理由を `artworkSkipped` に
/// 添える（値は Dart 側の `kNowPlayingArtworkSkipReasons` と揃える）。
final class NowPlayingPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "capsicum/now_playing",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getNowPlaying":
        handleGetNowPlaying(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func handleGetNowPlaying(result: @escaping FlutterResult) {
    switch MPMediaLibrary.authorizationStatus() {
    case .authorized:
      respond(result)
    case .notDetermined:
      // 初回押下時にここでダイアログが出る。許可されたら読み取り、それ以外は nil。
      MPMediaLibrary.requestAuthorization { status in
        if status == .authorized {
          respond(result)
        } else {
          DispatchQueue.main.async { result(nil) }
        }
      }
    case .denied, .restricted:
      result(nil)
    @unknown default:
      result(nil)
    }
  }

  /// ジャケットの読み出しが非同期なので、結果はメインスレッドへ戻して返す。
  private static func respond(_ result: @escaping FlutterResult) {
    Task {
      let map = await currentItemMap()
      await MainActor.run { result(map) }
    }
  }

  /// 現在ミュージックアプリにロードされている曲を title / artist / albumTitle の
  /// マップにする。曲が無い・メタデータが空なら nil（Dart 側で「曲なし」扱い）。
  /// 再生 / 一時停止は問わない（ユーザーは「今の曲」を入れたいだけ）。
  private static func currentItemMap() async -> [String: Any]? {
    guard
      let item = await MainActor.run(body: {
        MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
      })
    else { return nil }
    var map: [String: Any] = [:]
    if let title = item.title { map["title"] = title }
    if let artist = item.artist { map["artist"] = artist }
    if let album = item.albumTitle { map["albumTitle"] = album }
    if map.isEmpty { return nil }
    guard let data = await artworkData(of: item), !data.isEmpty else {
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

  /// ジャケットのバイト列 (#1275)。
  ///
  /// 1. **曲のファイルに埋め込まれた元のバイト列**（`assetURL` があるとき＝端末に
  ///    ある曲）。⚠ 形式を変えずにそのまま渡せるので、こちらを先に見る
  /// 2. 無ければ **OS が渡す画像を、その大きさのまま JPEG にする**（Apple Music の
  ///    ストリーミングの曲は `assetURL` が nil で、`MPMediaItemArtwork` はデコード
  ///    済みの画像しか返さない）。
  ///
  /// ⚠⚠ 2 は「形式変換を capsicum 側で作らない」（`docs/product-policy.md` の
  /// ナウプレ・#1133 決定事項 3）の例外に見えるが、目的（モロヘイヤの既存の
  /// 縮小・変換と重ねない）には触れない —— **縮小せず**、バイト列を得る手段が
  /// 他に無いから符号化するだけ。大きさの上限（10MB）と形式の判定は 1 と同じく
  /// [writeArtwork] が見る。
  private static func artworkData(of item: MPMediaItem) async -> Data? {
    if let url = item.assetURL {
      let asset = AVURLAsset(url: url)
      if let metadata = try? await asset.load(.commonMetadata) {
        let artwork = AVMetadataItem.metadataItems(
          from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        if let first = artwork.first, let data = try? await first.load(.dataValue) {
          return data
        }
      }
    }
    return await MainActor.run {
      guard let artwork = item.artwork else { return nil }
      let size = artwork.bounds.size
      guard size.width > 0, size.height > 0 else { return nil }
      return artwork.image(at: size)?.jpegData(compressionQuality: 0.9)
    }
  }

  // ⚠ 以下の書き出しと掃除は macOS（`macos/Runner/NowPlayingPlugin.swift`・#1273 /
  // #1283）と同じ規則。ターゲットが別で共有できないので複製してある。**片方を
  // 直したら、もう片方も直す。**

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

  /// アートワークのバイト列を一時ファイルへ書き出し、そのパスを返す。
  /// 書き出さなかった回は理由を返す（画像でない / 大きすぎる / 書けなかった）。
  ///
  /// ⚠ **置き場所は中身のハッシュで決める。**投稿フォームは「同じジャケットを
  /// 2 枚添付しない」を URI の一致で見ているので、同じ絵は同じパスに、違う絵は
  /// 違うパスになる必要がある。⚠ ファイル名は固定（そのまま投稿先のファイル名になる）。
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

  /// 古い書き出しを消す (#1283)。⚠ 失敗は握る（掃除は上積み）。
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
