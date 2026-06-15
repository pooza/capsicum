import CoreServices
import FlutterMacOS
import Foundation

/// ミュージック.app（Apple Music）の「現在再生中の曲」を AppleScript 経由で取得し、
/// Dart 側 AppleMusicNowPlayingProvider (#668) に返すプラグイン。
///
/// チャンネル名 `capsicum/now_playing` / メソッド `getNowPlaying` は iOS / Windows
/// SMTC (#484) と揃える（OS ネイティブ pull の共通入口）。
///
/// **App Sandbox 下の TCC「オートメーション」許可（#668 の難所、build 109-113 で実証）:**
/// - 対象アプリ（ミュージック.app）の解決は **メインスレッドでないと procNotFound
///   (-600)** になる（build 112=AEDetermine/bg、build 113=NSAppleScript/bg がともに
///   -600）。一方、NSAppleScript の同期送信をメインで行うと TCC プロンプトを描画する
///   run loop が塞がり、-1744 を握り潰して「曲なし」化けする（build 109/110）。
/// - 解は **メインスレッドで `AEDeterminePermissionToAutomateTarget` を使う**こと。
///   これは AESend のデッドロックなしに許可プロンプトを出せる公式 API。許可未決なら
///   プロンプトを出し（初回のみ・その間 UI は一瞬ブロック）、許可後にスクリプトを実行。
///
/// 失敗種別は `__nowPlayingError`（automation_denied / automation_pending / no_track /
/// script_error + __code）＋診断 `__automationStatus` で返す。実曲は title/artist を持つ。
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
        // メインスレッドで実行（対象アプリ解決が sandbox 下でメイン必須のため）。
        result(currentItemMap())
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
      return [
        "__nowPlayingError": "automation_denied", "__automationStatus": Int(status),
      ]
    case -1744:  // errAEEventWouldRequireUserConsent: 応答待ち
      return [
        "__nowPlayingError": "automation_pending", "__automationStatus": Int(status),
      ]
    default:
      // -600(procNotFound) 等。診断のため status を載せて no_track 化。
      return ["__nowPlayingError": "no_track", "__automationStatus": Int(status)]
    }
  }

  /// ミュージック.app への Apple Events 許可状態。promptIfNeeded=true なら未決時に
  /// TCC プロンプトを出す。**メインスレッドで呼ぶこと**（対象解決とプロンプト表示の
  /// ため。一瞬 UI を塞ぐが許可は初回のみ）。
  private static func automationPermissionStatus(promptIfNeeded: Bool) -> OSStatus {
    let desc = NSAppleEventDescriptor(bundleIdentifier: musicBundleID)
    guard let aeDescPtr = desc.aeDesc else { return OSStatus(-1700) }
    var mutableDesc = aeDescPtr.pointee
    return AEDeterminePermissionToAutomateTarget(
      &mutableDesc, typeWildCard, typeWildCard, promptIfNeeded)
  }

  /// 許可済み前提で現在の曲を照会する。`application "Music" is running` を tell の外で
  /// 判定し、未起動のミュージックを副作用で起動しない。許可は前段で確認済みのため、
  /// 曲読み取りの try は「再生中だが現在トラックなし」だけを吸収する。
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
        return [
          "__nowPlayingError": "automation_denied", "__code": code,
          "__automationStatus": Int(automationStatus),
        ]
      case -1744:
        return [
          "__nowPlayingError": "automation_pending", "__code": code,
          "__automationStatus": Int(automationStatus),
        ]
      default:
        return [
          "__nowPlayingError": "script_error", "__code": code,
          "__automationStatus": Int(automationStatus),
        ]
      }
    }
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
    if map["title"] == nil && map["artist"] == nil {
      return [
        "__nowPlayingError": "no_track", "__scriptItems": items,
        "__automationStatus": Int(automationStatus),
      ]
    }
    return map
  }
}
