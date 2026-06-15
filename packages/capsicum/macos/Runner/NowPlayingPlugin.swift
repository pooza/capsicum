import CoreServices
import FlutterMacOS
import Foundation

/// ミュージック.app（Apple Music）の「現在再生中の曲」を AppleScript 経由で取得し、
/// Dart 側 AppleMusicNowPlayingProvider (#668) に返すプラグイン。
///
/// チャンネル名 `capsicum/now_playing` / メソッド `getNowPlaying` は iOS / Windows
/// SMTC (#484) と揃える（OS ネイティブ pull の共通入口）。
///
/// iOS は MediaPlayer framework だが、macOS は他アプリ（ミュージック.app）への
/// 照会となるため AppleScript（Apple Events）を使う。App Sandbox 下では
/// `com.apple.security.automation.apple-events` entitlement と
/// `NSAppleEventsUsageDescription` が要る。
///
/// **TCC「オートメーション」許可は `AEDeterminePermissionToAutomateTarget` で能動的に
/// 問い合わせる**。これが肝で、AppleScript の `tell` 内 `try` に任せると、TCC 拒否
/// (-1743) / 応答待ち (-1744) を try が握り潰し、プロンプトも出ないまま空文字列が
/// 「正常」に返って「曲なし」へ化ける（#668 build 110 で実証。許可一覧に capsicum
/// すら載らなかった）。先に許可を問い合わせれば未決時にプロンプトが出て、拒否/応答
/// 待ちを Dart 側に明示できる。
///
/// 失敗種別は `__nowPlayingError`（automation_denied / automation_pending /
/// script_error + __code）で返し、未再生・ミュージック未起動・曲なしは nil
/// （Dart 側は「再生中の曲がありません」）。
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
        // しうるため、メインスレッドで呼ばない（Apple 推奨）。バックグラウンドで
        // 解決し、結果は main に戻して返す。
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
  /// 未起動・停止中・曲なしは nil。TCC 拒否 / 応答待ち / その他エラーは
  /// `__nowPlayingError` 付きマップで「曲なし(nil)」と区別する。
  private static func currentItemMap() -> [String: Any]? {
    // まず TCC「オートメーション」許可を問い合わせ、未決ならプロンプトを出す。
    let status = automationPermissionStatus(promptIfNeeded: true)
    switch status {
    case noErr:
      break
    case -1743:  // errAEEventNotPermitted: ユーザーが拒否
      return ["__nowPlayingError": "automation_denied"]
    case -1744:  // errAEEventWouldRequireUserConsent: 応答待ち
      return ["__nowPlayingError": "automation_pending"]
    case -600:  // procNotFound: ミュージック未起動 → 曲なし扱い
      return nil
    default:
      return ["__nowPlayingError": "script_error", "__code": Int(status)]
    }
    return runNowPlayingScript()
  }

  /// ミュージック.app への Apple Events 許可状態。promptIfNeeded=true なら未決時に
  /// TCC プロンプトを出す。noErr=許可済み / -1743=拒否 / -1744=応答待ち /
  /// -600=対象未起動。
  private static func automationPermissionStatus(promptIfNeeded: Bool) -> OSStatus {
    var target = AEAddressDesc()
    // AECreateDesc は OSErr(Int16) を返すため OSStatus(Int32) に揃える。
    let created = OSStatus(
      musicBundleID.withCString { ptr in
        AECreateDesc(
          typeApplicationBundleID, ptr, musicBundleID.utf8.count, &target)
      })
    guard created == noErr else { return created }
    defer { AEDisposeDesc(&target) }
    return AEDeterminePermissionToAutomateTarget(
      &target, typeWildCard, typeWildCard, promptIfNeeded)
  }

  /// 許可済み前提で現在の曲を照会する。`application "Music" is running` を tell の
  /// 外で判定し、未起動のミュージックを副作用で起動しない。曲読み取りの `try` は
  /// （許可は別途確認済みのため）「再生中だが現在トラックなし」だけを吸収する。
  private static func runNowPlayingScript() -> [String: Any]? {
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
        return ["__nowPlayingError": "automation_denied"]
      case -1744:
        return ["__nowPlayingError": "automation_pending"]
      default:
        return ["__nowPlayingError": "script_error", "__code": code]
      }
    }
    // 空 {} は 0 要素。曲があれば {name, artist, album} の 3 要素リスト。
    guard descriptor.numberOfItems >= 3 else { return nil }
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
    return map.isEmpty ? nil : map
  }
}
