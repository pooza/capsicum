import Cocoa
import FlutterMacOS

/// Intel Mac でだけ、描画エンジンを Impeller から従来の Skia へ戻す (#1299)。
///
/// Flutter 3.46 から macOS の既定が Impeller（flutter#186546）になり、capsicum は
/// v2.2.0 からその版で出ている。Intel Mac（MacBookPro16,1）の利用者から、
/// **起動すると画面にノイズが出て使えない**と報告があった。崩れ始めた時期が
/// Impeller に切り替わった版と合う。
///
/// ⚠⚠ **全 macOS には効かせない**（2026-10-18 pooza）。Info.plist の
/// `FLTEnableImpeller` は全端末に効くので使わず、エンジンが読む
/// `FlutterDartProject.enableImpeller`（非公開の property・
/// `FlutterDartProject_Internal.h`）を x86_64 のスライスでだけ上書きする。
/// Apple Silicon では上書きが無く、既定（Impeller）のまま。
///
/// ⚠⚠ **非公開の名前に乗っている。**上流が名前を変えると、**黙って効かなくなる**
/// （コンパイルは通る）。`macos_impeller_opt_out_guard_test.dart` が、手元の
/// Flutter SDK のエンジンのソースにこの名前が残っていることを見ている。
final class CapsicumDartProject: FlutterDartProject {
  #if arch(x86_64)
    @objc(enableImpeller) var capsicumEnableImpeller: Bool { false }
  #endif
}

class MainFlutterWindow: NSWindow {
  // UNUserNotificationCenter.delegate は weak のため、proxy (#674) を
  // window が強参照して生かしておく。
  private var notificationDedupPlugin: NotificationDedupPlugin?

  // 常駐状態を Dart から受ける channel (#757)。setMethodCallHandler の保持先として
  // window が強参照する。
  private var residentChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    // macOS 自動ウインドウタブ機能を無効化する (#712)。capsicum は単一ウインドウ
    // のため、既定 ON だと「表示」メニューに OS が「タブバーを表示」「すべての
    // タブを表示」を注入し、ウインドウ上部に意味のない "capsicum" タブが出る。
    // class プロパティでメニュー項目ごと抑止し、念のため当該ウインドウも
    // tabbingMode=.disallowed にする。
    NSWindow.allowsAutomaticWindowTabbing = false
    self.tabbingMode = .disallowed

    // 常駐モード (#757) でウィンドウを閉じてもプロセスを残すため、閉じても
    // ウィンドウ実体を解放しない。これでメニューバーから window_manager.show()
    // 再表示できる。close ボタンの「閉じる＝終了」抑止は AppDelegate の
    // applicationShouldTerminateAfterLastWindowClosed が担う。
    self.isReleasedWhenClosed = false

    let flutterViewController = FlutterViewController(
      project: CapsicumDartProject(precompiledDartBundle: nil)
    )
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

    // Apple Music ナウプレ取得 (#668)。ミュージック.app を AppleScript で照会する
    // "capsicum/now_playing" channel を提供する（iOS / Windows SMTC と共通）。
    NowPlayingPlugin.register(
      with: flutterViewController.registrar(forPlugin: "NowPlayingPlugin")
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
    // AppDelegate の didReceiveRemoteNotification → 掃除トリガ (#673) の配線。
    if let plugin = notificationDedupPlugin {
      (NSApp.delegate as? AppDelegate)?.attachDedupPlugin(plugin)
    }

    // 常駐モード (#757) の状態を Dart から受け取り AppDelegate に反映する channel。
    // 値は ResidentModeService.setEnabled が macOS のときに push する。
    let residentChannel = FlutterMethodChannel(
      name: "capsicum/resident",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    residentChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "setResidentActive":
        if let active = call.arguments as? Bool {
          (NSApp.delegate as? AppDelegate)?.setResidentActive(active)
          result(nil)
        } else {
          result(FlutterError(code: "bad_args", message: "expected Bool", details: nil))
        }
      case "setDockIconHidden":
        if let hidden = call.arguments as? Bool {
          (NSApp.delegate as? AppDelegate)?.setDockIconHidden(hidden)
          result(nil)
        } else {
          result(FlutterError(code: "bad_args", message: "expected Bool", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.residentChannel = residentChannel

    super.awakeFromNib()
  }
}
