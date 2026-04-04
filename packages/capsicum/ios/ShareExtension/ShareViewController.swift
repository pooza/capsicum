import UIKit

class ShareViewController: UIViewController {
  private let appGroupId = "group.jp.co.b-shock.capsicum"
  private let typeText = "public.plain-text"
  private let typeURL = "public.url"

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
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
