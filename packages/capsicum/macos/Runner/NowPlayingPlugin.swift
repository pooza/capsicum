import CoreServices
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
/// **TCC「オートメーション」許可は `AEDeterminePermissionToAutomateTarget` で能動的に
/// 問い合わせる**。AppleScript の `try` に任せると TCC 拒否(-1743)/応答待ち(-1744)を
/// try が握り潰し、プロンプトも出ないまま空が返って「曲なし」化けする（#668 build 110
/// で実証）。許可ターゲットは `NSAppleEventDescriptor(bundleIdentifier:)` で解決する。
///
/// build 111 でも「即・曲なし」が続き原因切り分けのため、戻り値に診断情報
/// （`__automationStatus` = AEDetermine の OSStatus、`__scriptItems` = スクリプトが
/// 返した要素数）を必ず載せ、Dart 側が Sentry に流せるようにした。失敗種別は
/// `__nowPlayingError`（automation_denied / automation_pending / no_track /
/// script_error + __code）。実曲は title/artist を持つマップ。
final class NowPlayingPlugin {
  private static let musicBundleID = "com.apple.Music"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "capsicum/now_playing",
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getNowPlaying":
        // AEDeterminePermissionToAutomateTarget は許可ダイアログ表示中ブロック
        // しうるため、メインスレッドで呼ばない（Apple 推奨）。
        DispatchQueue.global(qos: .userInitiated).async {
          let map = currentItemMap()
          DispatchQueue.main.async { result(map) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func currentItemMap() -> [String: Any]? {
    let status = automationPermissionStatus(promptIfNeeded: true)
    switch status {
    case noErr:
      return runNowPlayingScript(automationStatus: status)
    case -1743:  // errAEEventNotPermitted: 拒否
      return ["__nowPlayingError": "automation_denied", "__automationStatus": Int(status)]
    case -1744:  // errAEEventWouldRequireUserConsent: 応答待ち
      return ["__nowPlayingError": "automation_pending", "__automationStatus": Int(status)]
    default:
      // -600(procNotFound: 未起動) 等を含め、診断のため status を載せて no_track 化。
      return ["__nowPlayingError": "no_track", "__automationStatus": Int(status)]
    }
  }

  /// ミュージック.app への Apple Events 許可状態。promptIfNeeded=true なら未決時に
  /// TCC プロンプトを出す。ターゲットは bundleIdentifier で解決（AECreateDesc より
  /// 実行中プロセスの解決が確実）。
  private static func automationPermissionStatus(promptIfNeeded: Bool) -> OSStatus {
    let desc = NSAppleEventDescriptor(bundleIdentifier: musicBundleID)
    guard let aeDescPtr = desc.aeDesc else { return OSStatus(-1700) }
    var mutableDesc = aeDescPtr.pointee
    return AEDeterminePermissionToAutomateTarget(
      &mutableDesc, typeWildCard, typeWildCard, promptIfNeeded)
  }

  /// 許可済み前提で現在の曲を照会する。`application "Music" is running` を tell の
  /// 外で判定し、未起動のミュージックを副作用で起動しない。曲読み取りの `try` は
  /// 「再生中だが現在トラックなし」だけを吸収する（許可は前段で確認済み）。
  private static func runNowPlayingScript(automationStatus: OSStatus) -> [String: Any]? {
    let source = """
      if application "Music" is running then
        tell application "Music"
          if player state is stopped then return {}
          try
            return {name of current track, artist of current track, album of current track}
          on error
            return {}
          end try
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
      let code = (errorInfo?[NSAppleScript.errorNumber] as? Int) ?? 0
      switch code {
      case -1743:
        return ["__nowPlayingError": "automation_denied", "__automationStatus": Int(automationStatus)]
      case -1744:
        return ["__nowPlayingError": "automation_pending", "__automationStatus": Int(automationStatus)]
      default:
        return [
          "__nowPlayingError": "script_error", "__code": code,
          "__automationStatus": Int(automationStatus),
        ]
      }
    }
    // 空 {} は 0 要素。曲があれば {name, artist, album} の 3 要素リスト。
    let items = descriptor.numberOfItems
    guard items >= 3 else {
      return [
        "__nowPlayingError": "no_track", "__scriptItems": items,
        "__automationStatus": Int(automationStatus),
      ]
    }
    var map: [String: Any] = ["__automationStatus": Int(automationStatus)]
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
    // title も artist も無ければ no_track 扱い（診断情報は残す）。
    if map["title"] == nil && map["artist"] == nil {
      return [
        "__nowPlayingError": "no_track", "__scriptItems": items,
        "__automationStatus": Int(automationStatus),
      ]
    }
    return map
  }
}
