import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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

    super.awakeFromNib()
  }
}
