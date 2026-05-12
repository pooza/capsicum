import Cocoa
import os.log

/// macOS Share Extension entry point.
///
/// iOS 版と同様、共有メニューから渡された URL / プレーンテキストを App Group
/// コンテナの `shared_text.txt` に書き出し、本体（capsicum）が起動時に
/// [ShareIntentPlugin] 経由でポーリング消費する。compose UI はモバイル本体で
/// 表示するため、ここでは即時保存・close で UI を出さない。
///
/// NSViewController を継承しているので NSObject 経由で ObjC runtime に
/// `ShareExtension.ShareViewController` として自動登録される。Info.plist の
/// `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController` と
/// マッチする。`@objc(...)` で ObjC 名を上書きすると Swift module 名側の
/// 登録が消え、NSClassFromString で nil が返るので付けない。
class ShareViewController: NSViewController {
  // ShareExtension と本体が共有する識別子は以下 4 ファイルにベタ書きで重複している
  // (Xcode の同一 .swift を 2 target に member 追加するコストを避けるため。#508):
  //   - macos/Runner/ShareIntentPlugin.swift
  //   - macos/ShareExtension/ShareViewController.swift  （本ファイル）
  //   - ios/Runner/ShareIntentPlugin.swift
  //   - ios/ShareExtension/ShareViewController.swift
  // 変更時は 4 箇所同期すること。書き込み先ファイル名 "shared_text.txt" も同様。
  private let appGroupId = "group.jp.co.b-shock.capsicum"
  private let typeText = "public.plain-text"
  private let typeURL = "public.url"
  private let log = OSLog(
    subsystem: "jp.co.b-shock.capsicum.ShareExtension",
    category: "share"
  )

  override func loadView() {
    self.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    os_log("loadView called", log: log, type: .debug)
  }

  /// macOS NSExtensionPrincipalClass 経路では viewDidAppear が確実に発火する
  /// 保証がないため、viewDidLoad で先に処理を起動する。`handled` フラグで
  /// viewDidAppear と二重実行されないようにガード。
  private var handled = false

  override func viewDidLoad() {
    super.viewDidLoad()
    os_log("viewDidLoad called", log: log, type: .debug)
    handleOnce()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    os_log("viewDidAppear called", log: log, type: .debug)
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
    os_log("inputItems count=%d", log: log, type: .debug, items.count)

    for (i, item) in items.enumerated() {
      guard let attachments = item.attachments else {
        os_log("item[%d] has no attachments", log: log, type: .debug, i)
        continue
      }
      os_log("item[%d] attachments count=%d", log: log, type: .debug, i, attachments.count)

      for (j, provider) in attachments.enumerated() {
        let types = provider.registeredTypeIdentifiers
        os_log(
          "item[%d].provider[%d] types=%{public}@",
          log: log, type: .debug, i, j, types.joined(separator: ",")
        )

        if provider.hasItemConformingToTypeIdentifier(typeURL) {
          os_log("matched typeURL, loading...", log: log, type: .debug)
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
          os_log("matched typeText, loading...", log: log, type: .debug)
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

  /// loadItem コールバックで渡される data は静的型 `(any NSSecureCoding)?` で、
  /// macOS Music.app は URL / NSURL / String / NSString のどれでもなく
  /// Data や別の型で URL を渡してくることがある (#422 の TestFlight +57 で観測)。
  /// 型を一通り試して URL 文字列を抽出し、抽出できた値を App Group に保存する。
  /// 識別できなかった場合は実際の runtime 型と String 表現をログに残す。
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

    // 共有された値は URL / テキスト本体 (機微情報候補) のため、type 判別の
    // 文字列のみ public に残し、value は %{private}@ で Console.app からの
    // 平文読み取りを抑制する (#518 / 差分レビュー)。
    if let url = unwrapped as? URL {
      os_log("matched URL: %{private}@", log: log, type: .debug, url.absoluteString)
      saveSharedText(url.absoluteString)
      return
    }
    if let nsurl = unwrapped as? NSURL, let abs = nsurl.absoluteString {
      os_log("matched NSURL: %{private}@", log: log, type: .debug, abs)
      saveSharedText(abs)
      return
    }
    if let str = unwrapped as? String {
      os_log("matched String: %{private}@", log: log, type: .debug, str)
      saveSharedText(str)
      return
    }
    if let nsstr = unwrapped as? NSString {
      let s = nsstr as String
      os_log("matched NSString: %{private}@", log: log, type: .debug, s)
      saveSharedText(s)
      return
    }
    if let bytes = unwrapped as? Data, let str = String(data: bytes, encoding: .utf8) {
      os_log("matched Data utf8: %{private}@", log: log, type: .debug, str)
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
    os_log(
      "containerURL: %{public}@",
      log: log, type: .debug, containerURL.path
    )
    let fileURL = containerURL.appendingPathComponent("shared_text.txt")
    do {
      try text.write(to: fileURL, atomically: true, encoding: .utf8)
      os_log(
        "wrote %d chars to %{public}@",
        log: log, type: .debug, text.count, fileURL.path
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
