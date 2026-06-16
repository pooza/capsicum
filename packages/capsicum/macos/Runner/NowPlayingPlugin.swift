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
/// script_error + __code）で返す。実曲は title/artist を持つマップ。
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
  private static func currentItemMap() -> [String: Any]? {
    let source = """
      if application "Music" is running then
        tell application "Music"
          if player state is stopped then return {}
          return {name of current track, artist of current track, album of current track}
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
    return map
  }
}
