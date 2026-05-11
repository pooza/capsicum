import UIKit
import os.log

class ShareViewController: UIViewController {
  // ShareExtension と本体が共有する識別子は以下 4 ファイルにベタ書きで重複している
  // (Xcode の同一 .swift を 2 target に member 追加するコストを避けるため。#508):
  //   - macos/Runner/ShareIntentPlugin.swift
  //   - macos/ShareExtension/ShareViewController.swift
  //   - ios/Runner/ShareIntentPlugin.swift
  //   - ios/ShareExtension/ShareViewController.swift  （本ファイル）
  // 変更時は 4 箇所同期すること。書き込み先ファイル名 "shared_text.txt" も同様。
  private let appGroupId = "group.jp.co.b-shock.capsicum"
  private let typeText = "public.plain-text"
  private let typeURL = "public.url"
  private let log = OSLog(
    subsystem: "jp.co.b-shock.capsicum.ShareExtension",
    category: "share"
  )

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    handleSharedItems()
  }

  private func handleSharedItems() {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
      os_log("inputItems is nil or not [NSExtensionItem]", log: log, type: .error)
      close()
      return
    }
    os_log("inputItems count=%d", log: log, type: .debug, items.count)

    for item in items {
      guard let attachments = item.attachments else { continue }
      for provider in attachments {
        if provider.hasItemConformingToTypeIdentifier(typeURL) {
          provider.loadItem(forTypeIdentifier: typeURL, options: nil) { [weak self] data, error in
            if let error = error {
              os_log(
                "loadItem(URL) error: %{public}@",
                log: self?.log ?? .default, type: .error,
                error.localizedDescription
              )
            }
            self?.handleLoadedItem(data, label: "typeURL")
            self?.close()
          }
          return
        }
        if provider.hasItemConformingToTypeIdentifier(typeText) {
          provider.loadItem(forTypeIdentifier: typeText, options: nil) { [weak self] data, error in
            if let error = error {
              os_log(
                "loadItem(text) error: %{public}@",
                log: self?.log ?? .default, type: .error,
                error.localizedDescription
              )
            }
            self?.handleLoadedItem(data, label: "typeText")
            self?.close()
          }
          return
        }
      }
    }
    os_log("no matching provider found, closing", log: log, type: .error)
    close()
  }

  /// loadItem の戻り値は静的型 `(any NSSecureCoding)?` で、Music.app は
  /// URL を `_NSInlineData` (NSData の private 派生) で渡してくる
  /// (#422 macOS +59 で観測。iOS でも同じ可能性があるため preemptive に
  /// 多経路フォールバックを入れる)。URL / NSURL / String / NSString / Data
  /// を順に試して URL 文字列を抽出する。
  private func handleLoadedItem(_ data: NSSecureCoding?, label: String) {
    guard let unwrapped = data else {
      os_log("loadItem(%{public}@) returned nil", log: log, type: .error, label)
      return
    }
    let actualType = String(describing: type(of: unwrapped))
    os_log(
      "loadItem(%{public}@) actualType=%{public}@",
      log: log, type: .debug, label, actualType
    )

    if let url = unwrapped as? URL {
      saveSharedText(url.absoluteString)
      return
    }
    if let nsurl = unwrapped as? NSURL, let abs = nsurl.absoluteString {
      saveSharedText(abs)
      return
    }
    if let str = unwrapped as? String {
      saveSharedText(str)
      return
    }
    if let nsstr = unwrapped as? NSString {
      saveSharedText(nsstr as String)
      return
    }
    if let bytes = unwrapped as? Data, let str = String(data: bytes, encoding: .utf8) {
      saveSharedText(str)
      return
    }

    // value は共有された URL / テキスト本体になりうる (機微情報候補)。
    // %{private}@ にして Configuration Profile を入れない限り Console.app
    // で読めないようにする (#518)。type は誤判定をデバッグするため public のまま。
    let stringRep = String(describing: unwrapped)
    os_log(
      "no fallback matched. type=%{public}@ value=%{private}@",
      log: log, type: .error, actualType, stringRep
    )
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
    let fileURL = containerURL.appendingPathComponent("shared_text.txt")
    do {
      try text.write(to: fileURL, atomically: true, encoding: .utf8)
      os_log(
        "wrote %d chars to shared_text.txt",
        log: log, type: .debug, text.count
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
