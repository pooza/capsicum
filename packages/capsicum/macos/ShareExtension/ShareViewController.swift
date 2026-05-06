import Cocoa

/// macOS Share Extension entry point.
///
/// iOS 版と同様、共有メニューから渡された URL / プレーンテキストを App Group
/// コンテナの `shared_text.txt` に書き出し、本体（capsicum）が起動時に
/// [ShareIntentPlugin] 経由でポーリング消費する。compose UI はモバイル本体で
/// 表示するため、ここでは即時保存・close で UI を出さない。
///
/// `@objc(ShareViewController)` を付けて Info.plist の
/// `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController` から
/// Objective-C runtime 経由で解決できるようにする。
@objc(ShareViewController)
class ShareViewController: NSViewController {
  private let appGroupId = "group.jp.co.b-shock.capsicum"
  private let typeText = "public.plain-text"
  private let typeURL = "public.url"

  override func loadView() {
    self.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    handleSharedItems()
  }

  private func handleSharedItems() {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
      close()
      return
    }

    for item in items {
      guard let attachments = item.attachments else { continue }
      for provider in attachments {
        if provider.hasItemConformingToTypeIdentifier(typeURL) {
          provider.loadItem(forTypeIdentifier: typeURL, options: nil) { [weak self] data, _ in
            if let url = data as? URL {
              self?.saveSharedText(url.absoluteString)
            } else if let text = data as? String {
              self?.saveSharedText(text)
            }
            self?.close()
          }
          return
        }
        if provider.hasItemConformingToTypeIdentifier(typeText) {
          provider.loadItem(forTypeIdentifier: typeText, options: nil) { [weak self] data, _ in
            if let text = data as? String {
              self?.saveSharedText(text)
            }
            self?.close()
          }
          return
        }
      }
    }
    close()
  }

  private func saveSharedText(_ text: String) {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else { return }
    let fileURL = containerURL.appendingPathComponent("shared_text.txt")
    try? text.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  private func close() {
    DispatchQueue.main.async {
      self.extensionContext?.completeRequest(returningItems: nil)
    }
  }
}
