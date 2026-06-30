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

  // 配信済み generic 通知の掃除トリガ (#673)。MainFlutterWindow が install 後に
  // attach する (強参照は MainFlutterWindow 側が保持)。
  private weak var dedupPlugin: NotificationDedupPlugin?

  // 常駐モード (#752 / macOS は #757) が ON のあいだだけ true。MainFlutterWindow が
  // "capsicum/resident" channel 経由で Dart から張り替える。
  private var residentActive: Bool = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 常駐 ON のときはウィンドウを閉じてもプロセスを残す（メニューバー常駐）。
    // window_manager の preventClose は macOS embedder では close を止めきれず
    // （close イベントは出るが実際には閉じる・#757 の debug 実機で確認）、ここで
    // 終了を抑止しないと閉じた瞬間にアプリごと終わってしまう。MainFlutterWindow は
    // isReleasedWhenClosed=false なのでウィンドウ実体は残り、メニューバーから再表示
    // できる。非常駐時は従来どおり最後のウィンドウを閉じたら終了する。
    return !residentActive
  }

  /// MainFlutterWindow が "capsicum/resident" channel 経由で常駐状態を反映する。
  func setResidentActive(_ active: Bool) {
    residentActive = active
  }

  /// Dock アイコン / アプリスイッチャからの出し入れ (#757)。常駐中にウィンドウを
  /// 隠したら .accessory（メニューバーのみ＝Dock から消える）、表示に戻すときは
  /// .regular。ウィンドウを隠した直後に .accessory へ移すこと（key window があると
  /// 切替が効きにくいため hide → accessory の順を Dart 側で守る）。
  func setDockIconHidden(_ hidden: Bool) {
    NSApp.setActivationPolicy(hidden ? .accessory : .regular)
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

  /// MainFlutterWindow が NotificationDedupPlugin install 後に attach する。
  func attachDedupPlugin(_ plugin: NotificationDedupPlugin) {
    dedupPlugin = plugin
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
    didReceiveRemoteNotification userInfo: [String: Any]
  ) {
    // アプリ起動中に APNs が届いた合図。macOS は NSE (#673) が機能しないため
    // generic 文面の banner がこの直後に配信される。Dart 側
    // DeliveredPushCleaner に掃除をトリガする。token 系 override と同じく
    // super を呼ぶと doesNotRecognizeSelector でクラッシュするため呼ばない。
    dedupPlugin?.notifyRemoteArrived()
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
