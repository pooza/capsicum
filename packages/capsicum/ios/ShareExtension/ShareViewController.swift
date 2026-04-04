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
      NSLog("capsicum: ShareExtension no input items")
      close()
      return
    }

    NSLog("capsicum: ShareExtension received %d items", items.count)

    for item in items {
      guard let attachments = item.attachments else { continue }
      for provider in attachments {
        let types = provider.registeredTypeIdentifiers
        NSLog("capsicum: ShareExtension provider types: %@", types)

        if provider.hasItemConformingToTypeIdentifier(typeURL) {
          provider.loadItem(forTypeIdentifier: typeURL, options: nil) { [weak self] data, error in
            NSLog("capsicum: ShareExtension URL data=%@, error=%@", "\(String(describing: data))", "\(String(describing: error))")
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
          provider.loadItem(forTypeIdentifier: typeText, options: nil) { [weak self] data, error in
            NSLog("capsicum: ShareExtension text data=%@, error=%@", "\(String(describing: data))", "\(String(describing: error))")
            if let text = data as? String {
              self?.saveSharedText(text)
            }
            self?.close()
          }
          return
        }
      }
    }
    NSLog("capsicum: ShareExtension no matching type found")
    close()
  }

  private func saveSharedText(_ text: String) {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
      NSLog("capsicum: ShareExtension failed to get App Group container")
      return
    }
    let fileURL = containerURL.appendingPathComponent("shared_text.txt")
    do {
      try text.write(to: fileURL, atomically: true, encoding: .utf8)
      NSLog("capsicum: ShareExtension saved '%@' to %@", text, fileURL.path)
    } catch {
      NSLog("capsicum: ShareExtension save failed: %@", "\(error)")
    }
  }

  private func close() {
    DispatchQueue.main.async {
      self.extensionContext?.completeRequest(returningItems: nil)
    }
  }
}
