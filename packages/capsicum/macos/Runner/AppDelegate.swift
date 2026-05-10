import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
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
}
