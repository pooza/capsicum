import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // APNs デバイストークンを Dart に渡す MethodChannel (#468)。iOS と同じ
  // "net.shrieker.capsicum/apns" を使い、Dart 側 ApnsService をそのまま流用する。
  // MainFlutterWindow が engine 準備後に attachApnsChannel(_:) で渡す。token が
  // channel attach より先に届いた場合は buffer して attach 時に flush する
  // (iOS AppDelegate と同型)。
  private var apnsChannel: FlutterMethodChannel?
  private var pendingDeviceToken: String?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// MainMenu.xib の "About capsicum" メニューから First Responder 経由で呼ばれる。
  /// Drawer の「capsicum について」と同じ Flutter 側ダイアログを開く。
  @objc func showAboutDialog(_ sender: Any?) {
    AboutMenuPlugin.requestShowAbout()
  }

  /// MainFlutterWindow が engine 準備後に APNs channel を attach する。
  /// 先に届いていた token があれば flush する。
  func attachApnsChannel(_ channel: FlutterMethodChannel) {
    apnsChannel = channel
    if let token = pendingDeviceToken {
      channel.invokeMethod("onDeviceToken", arguments: token)
      pendingDeviceToken = nil
    }
  }

  // MARK: - APNs (#468)

  // FlutterAppDelegate (macOS) はこれらを open func で宣言するため compile 上は
  // override が必須。だが基底はセレクタを runtime で実装しておらず、
  // super.application(...) を呼ぶと -[NSObject doesNotRecognizeSelector:] →
  // SIGABRT で起動クラッシュする（内部ベータ 1.34.0+97 で実証、crash
  // 2026-06-07）。iOS は基底が forwarding を実装するため super を呼べるが、
  // macOS では super を呼ばず本 override で完結させる。
  // 通知の「タップ」配線は flutter_local_notifications (#569) が
  // UNUserNotificationCenter delegate を保持しているため本 AppDelegate では
  // 奪わない（タップ→画面遷移の parity は実機検証で確認する）。
  override func application(
    _ application: NSApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    if let channel = apnsChannel {
      channel.invokeMethod("onDeviceToken", arguments: token)
    } else {
      // engine / channel がまだ無ければ buffer して attach 時に flush。
      pendingDeviceToken = token
    }
  }

  override func application(
    _ application: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    // localizedDescription だけだと OSStatus 数値しか出ず原因特定に足りないため、
    // domain / code / userInfo も載せて Dart 側に渡す (#468 切り分け)。
    let ns = error as NSError
    let detail =
      "\(ns.domain) code=\(ns.code) \(ns.localizedDescription) userInfo=\(ns.userInfo)"
    apnsChannel?.invokeMethod("onDeviceTokenError", arguments: detail)
  }
}
