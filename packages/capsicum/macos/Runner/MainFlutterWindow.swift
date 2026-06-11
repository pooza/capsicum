import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // UNUserNotificationCenter.delegate は weak のため、proxy (#674) を
  // window が強参照して生かしておく。
  private var notificationDedupPlugin: NotificationDedupPlugin?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // ShareExtension からの shared_text.txt を消費する MethodChannel
    // (#422)。iOS と同じ "net.shrieker.capsicum/share" を提供する。
    ShareIntentPlugin.register(
      with: flutterViewController.registrar(forPlugin: "ShareIntentPlugin")
    )

    // メニューバー "About capsicum" → Flutter 側 About ダイアログを開く
    // MethodChannel "net.shrieker.capsicum/about" を提供する。
    AboutMenuPlugin.register(
      with: flutterViewController.registrar(forPlugin: "AboutMenuPlugin")
    )

    // APNs push (#468)。iOS と同じ "net.shrieker.capsicum/apns" channel を張り、
    // AppDelegate に attach する。AppDelegate が
    // didRegisterForRemoteNotificationsWithDeviceToken で受けた token を
    // この channel 経由で Dart の ApnsService に流す。engine 準備後の
    // awakeFromNib で登録要求を出す（token は非同期に AppDelegate へ届く）。
    let apnsChannel = FlutterMethodChannel(
      name: "net.shrieker.capsicum/apns",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    (NSApp.delegate as? AppDelegate)?.attachApnsChannel(apnsChannel)
    NSApplication.shared.registerForRemoteNotifications()

    // 起動中二重通知の dedup proxy (#674)。flutter_local_notifications が
    // RegisterGeneratedPlugins で UNUserNotificationCenter delegate を設定した
    // 後に包む必要があるため、この位置で install する。
    notificationDedupPlugin = NotificationDedupPlugin.install(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}
