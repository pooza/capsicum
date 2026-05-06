import Cocoa
import os.log

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
  private let log = OSLog(
    subsystem: "jp.co.b-shock.capsicum.ShareExtension",
    category: "share"
  )

  override func loadView() {
    self.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    os_log("loadView called", log: log, type: .info)
  }

  /// macOS NSExtensionPrincipalClass 経路では viewDidAppear が確実に発火する
  /// 保証がないため、viewDidLoad で先に処理を起動する。`handled` フラグで
  /// viewDidAppear と二重実行されないようにガード。
  private var handled = false

  override func viewDidLoad() {
    super.viewDidLoad()
    os_log("viewDidLoad called", log: log, type: .info)
    handleOnce()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    os_log("viewDidAppear called", log: log, type: .info)
    handleOnce()
  }

  private func handleOnce() {
    guard !handled else { return }
    handled = true
    handleSharedItems()
  }

  private func handleSharedItems() {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
      os_log("inputItems is nil or not [NSExtensionItem]", log: log, type: .error)
      close()
      return
    }
    os_log("inputItems count=%d", log: log, type: .info, items.count)

    for (i, item) in items.enumerated() {
      guard let attachments = item.attachments else {
        os_log("item[%d] has no attachments", log: log, type: .info, i)
        continue
      }
      os_log("item[%d] attachments count=%d", log: log, type: .info, i, attachments.count)

      for (j, provider) in attachments.enumerated() {
        let types = provider.registeredTypeIdentifiers
        os_log(
          "item[%d].provider[%d] types=%{public}@",
          log: log, type: .info, i, j, types.joined(separator: ",")
        )

        if provider.hasItemConformingToTypeIdentifier(typeURL) {
          os_log("matched typeURL, loading...", log: log, type: .info)
          provider.loadItem(forTypeIdentifier: typeURL, options: nil) { [weak self] data, error in
            if let error = error {
              os_log(
                "loadItem(URL) error: %{public}@",
                log: self?.log ?? .default, type: .error,
                error.localizedDescription
              )
            }
            if let url = data as? URL {
              os_log(
                "got URL: %{public}@",
                log: self?.log ?? .default, type: .info,
                url.absoluteString
              )
              self?.saveSharedText(url.absoluteString)
            } else if let text = data as? String {
              os_log(
                "got String for typeURL: %{public}@",
                log: self?.log ?? .default, type: .info,
                text
              )
              self?.saveSharedText(text)
            } else {
              os_log(
                "loadItem(URL) returned unexpected type: %{public}@",
                log: self?.log ?? .default, type: .error,
                String(describing: type(of: data))
              )
            }
            self?.close()
          }
          return
        }
        if provider.hasItemConformingToTypeIdentifier(typeText) {
          os_log("matched typeText, loading...", log: log, type: .info)
          provider.loadItem(forTypeIdentifier: typeText, options: nil) { [weak self] data, error in
            if let error = error {
              os_log(
                "loadItem(text) error: %{public}@",
                log: self?.log ?? .default, type: .error,
                error.localizedDescription
              )
            }
            if let text = data as? String {
              os_log(
                "got text: %{public}@",
                log: self?.log ?? .default, type: .info,
                text
              )
              self?.saveSharedText(text)
            }
            self?.close()
          }
          return
        }
      }
    }
    os_log("no matching provider found, closing", log: log, type: .error)
    close()
  }

  private func saveSharedText(_ text: String) {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
      os_log(
        "containerURL is nil for App Group %{public}@ — entitlement / provisioning profile issue?",
        log: log, type: .error, appGroupId
      )
      return
    }
    os_log(
      "containerURL: %{public}@",
      log: log, type: .info, containerURL.path
    )
    let fileURL = containerURL.appendingPathComponent("shared_text.txt")
    do {
      try text.write(to: fileURL, atomically: true, encoding: .utf8)
      os_log(
        "wrote %d chars to %{public}@",
        log: log, type: .info, text.count, fileURL.path
      )
    } catch {
      os_log(
        "write failed: %{public}@",
        log: log, type: .error, error.localizedDescription
      )
    }
  }

  private func close() {
    DispatchQueue.main.async {
      self.extensionContext?.completeRequest(returningItems: nil)
    }
  }
}
