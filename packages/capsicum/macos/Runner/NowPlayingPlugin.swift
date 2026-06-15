import FlutterMacOS
import Foundation

/// ミュージック.app（Apple Music）の「現在再生中の曲」を AppleScript 経由で取得し、
/// Dart 側 AppleMusicNowPlayingProvider (#668) に返すプラグイン。
///
/// チャンネル名 `capsicum/now_playing` / メソッド `getNowPlaying` は iOS / Windows
/// SMTC (#484) と揃える（OS ネイティブ pull の共通入口）。
///
/// macOS は他アプリ（ミュージック.app）への照会となるため AppleScript（Apple
/// Events）を使う。App Sandbox 下では `com.apple.security.automation.apple-events`
/// entitlement と `NSAppleEventsUsageDescription` が要る。
///
/// **TCC「オートメーション」許可の出し方（#668 の難所）:**
/// - スクリプト内の `try` で曲読み取りを囲うと、TCC 拒否(-1743)/応答待ち(-1744)を
///   try が握り潰し、プロンプトも出ないまま空が返り「曲なし」化けする（build 110）。
/// - `AEDeterminePermissionToAutomateTarget` で能動許可要求も試したが、App Sandbox
///   下では対象を解決できず **procNotFound(-600)** を返してスクリプトに到達すらせず
///   失敗した（build 112 の Sentry で確定）。
/// - 結論: **バックグラウンドスレッドで（メインを塞がず＝プロンプトが描画できる）、
///   `try` で包まずに直接スクリプトを実行する**。最初の Apple Event 送信で TCC が
///   プロンプトを出し、拒否/応答待ちは executeAndReturnError の errorNumber に出る。
///
/// 失敗種別は `__nowPlayingError`（automation_denied / automation_pending /
/// no_track / script_error + __code / __scriptItems）で返し、Dart 側が許可案内や
/// Sentry 観測に振り分ける。実曲は title/artist を持つマップ。
final class NowPlayingPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "capsicum/now_playing",
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getNowPlaying":
        // メインスレッドで同期送信すると、TCC プロンプトを描画するメイン run loop
        // が塞がり、プロンプトが出ないまま -1744 が返る。バックグラウンドで送る。
        DispatchQueue.global(qos: .userInitiated).async {
          let map = currentItemMap()
          DispatchQueue.main.async { result(map) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// ミュージック.app の現在の曲を title / artist / albumTitle のマップにする。
  /// `application "Music" is running` を tell の外で判定し、未起動のミュージックを
  /// 副作用で起動しない。**曲読み取りを try で包まない**ことで、TCC 拒否/応答待ちを
  /// executeAndReturnError に表面化させる（握り潰すとプロンプトが出ない）。
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
      // （-1728 の「現在トラックなし」等を含む）は観測用に code を添えて返す。
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
    // 空 {} は 0 要素。曲があれば {name, artist, album} の 3 要素リスト。
    let items = descriptor.numberOfItems
    guard items >= 3 else {
      return ["__nowPlayingError": "no_track", "__scriptItems": items]
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
    // title も artist も無ければ no_track 扱い。
    if map["title"] == nil && map["artist"] == nil {
      return ["__nowPlayingError": "no_track", "__scriptItems": items]
    }
    return map
  }
}
