import AppKit
import CoreServices
import FlutterMacOS
import Foundation

/// ミュージック.app（Apple Music）の「現在再生中の曲」を AppleScript 経由で取得し、
/// Dart 側 AppleMusicNowPlayingProvider (#668) に返すプラグイン。
///
/// チャンネル名 `capsicum/now_playing` / メソッド `getNowPlaying` は iOS / Windows
/// SMTC (#484) と揃える（OS ネイティブ pull の共通入口）。
///
/// **App Sandbox 下の TCC「オートメーション」許可（#668 の難所、build 109-114 で実証）:**
/// - `AEDeterminePermissionToAutomateTarget` を **bundleId 記述子**で呼ぶと、対象を
///   解決できず thread を問わず **procNotFound(-600)** になる（build 112/114）。
///   sandbox が bundleId でのオートメーション対象解決を弾くため。
/// - 一方 `NSWorkspace.runningApplications` でミュージックの **PID を取得し、PID
///   記述子（typeKernelProcessID）で AEDetermine を呼ぶと解決できる**（swiftc 検証で
///   noErr を確認）。実在プロセスを直接指すため -600 を回避できる。
/// - 許可未決なら AEDetermine がプロンプトを出す（AESend のデッドロックなし）。許可後に
///   名前指定の AppleScript（メインで解決可・109/110 で実証）で曲を読む。
///
/// 失敗種別は `__nowPlayingError`（automation_denied / automation_pending / no_track /
/// script_error + __code）＋診断 `__automationStatus`。実曲は title/artist を持つ。
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
        // メインスレッドで実行（AEDetermine のプロンプト表示・対象解決のため）。
        result(currentItemMap())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 実行中のミュージック.app の PID。未起動なら nil（起動はしない）。
  private static func musicPID() -> pid_t? {
    NSWorkspace.shared.runningApplications
      .first(where: { $0.bundleIdentifier == musicBundleID })?
      .processIdentifier
  }

  private static func currentItemMap() -> [String: Any]? {
    guard let pid = musicPID() else {
      // ミュージック未起動 → 曲なし（副作用で起動しない）。
      return ["__nowPlayingError": "no_track", "__reason": "not_running"]
    }
    let status = automationPermissionStatus(pid: pid, promptIfNeeded: true)
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
      return ["__nowPlayingError": "no_track", "__automationStatus": Int(status)]
    }
  }

  /// PID 記述子でミュージック.app への Apple Events 許可状態を問い合わせる。
  /// promptIfNeeded=true なら未決時に TCC プロンプトを出す。bundleId 記述子だと
  /// sandbox 下で -600 になるため、実在 PID を直接指す。
  private static func automationPermissionStatus(pid: pid_t, promptIfNeeded: Bool)
    -> OSStatus
  {
    let desc = NSAppleEventDescriptor(processIdentifier: pid)
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
