import Flutter

/// Flutter Plugin that reads shared text written by ShareExtension
/// via the App Group container.
///
/// Channel: net.shrieker.capsicum/share
/// Method:  getSharedText -> String?
public class ShareIntentPlugin: NSObject, FlutterPlugin {
  // ShareExtension と本体が共有する識別子は以下 4 ファイルにベタ書きで重複している
  // (Xcode の同一 .swift を 2 target に member 追加するコストを避けるため。#508):
  //   - macos/Runner/ShareIntentPlugin.swift
  //   - macos/ShareExtension/ShareViewController.swift
  //   - ios/Runner/ShareIntentPlugin.swift            （本ファイル）
  //   - ios/ShareExtension/ShareViewController.swift
  // 変更時は 4 箇所同期すること。MethodChannel 名 "net.shrieker.capsicum/share"
  // も同様。
  private static let appGroupId = "group.jp.co.b-shock.capsicum"
  private static let fileName = "shared_text.txt"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "net.shrieker.capsicum/share",
      binaryMessenger: registrar.messenger()
    )
    let instance = ShareIntentPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "getSharedText":
      result(consumeSharedText())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Reads and deletes the shared text file from the App Group container.
  private func consumeSharedText() -> String? {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroupId
    ) else {
      return nil
    }
    let fileURL = containerURL.appendingPathComponent(Self.fileName)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    do {
      let text = try String(contentsOf: fileURL, encoding: .utf8)
      try FileManager.default.removeItem(at: fileURL)
      return text.isEmpty ? nil : text
    } catch {
      return nil
    }
  }
}
