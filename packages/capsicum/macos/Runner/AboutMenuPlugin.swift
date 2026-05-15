import FlutterMacOS

/// macOS メニューバー「About capsicum」から Flutter 側 About ダイアログを開くための
/// MethodChannel `net.shrieker.capsicum/about` を提供する。
///
/// Drawer の「capsicum について」と同じダイアログを `main.dart` 側で開く。
/// AppDelegate.showAboutDialog(_:) から `requestShowAbout()` 経由で呼ばれる。
public class AboutMenuPlugin: NSObject, FlutterPlugin {
  private static var channel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(
      name: "net.shrieker.capsicum/about",
      binaryMessenger: registrar.messenger
    )
  }

  /// Flutter 側 About ダイアログを開くよう要求する。
  static func requestShowAbout() {
    channel?.invokeMethod("showAbout", arguments: nil)
  }
}
