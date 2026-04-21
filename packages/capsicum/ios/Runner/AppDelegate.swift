import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // UNUserNotificationCenterDelegate は FlutterAppDelegate が既に準拠済み
  // （Xcode 26 / Flutter SDK 3.32+）。このため、ここで再宣言する必要はなく、
  // userNotificationCenter(_:didReceive:) は override する。
  private var apnsChannel: FlutterMethodChannel?
  private var pendingDeviceToken: String?
  // Notification tapped before the Flutter engine was ready — deliver once
  // the channel becomes available (see didInitializeImplicitFlutterEngine).
  private var pendingNotificationTap: [AnyHashable: Any]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Request APNs device token. This does not trigger a user-facing
    // permission dialog; it only asks iOS for the token.
    application.registerForRemoteNotifications()

    // Become the UNUserNotificationCenter delegate so we can route taps
    // through the APNs MethodChannel to Dart (account-aware routing).
    UNUserNotificationCenter.current().delegate = self

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShareIntentPlugin") {
      ShareIntentPlugin.register(with: registrar)
    }

    // Set up the APNs MethodChannel after the Flutter engine is ready.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ApnsPlugin") {
      apnsChannel = FlutterMethodChannel(
        name: "net.shrieker.capsicum/apns",
        binaryMessenger: registrar.messenger()
      )
      // If the token arrived before the engine was initialized, send it now.
      if let token = pendingDeviceToken {
        apnsChannel?.invokeMethod("onDeviceToken", arguments: token)
        pendingDeviceToken = nil
      }
      // If a notification was tapped during cold start (before the engine
      // came up), deliver it now so Dart can route to the correct account.
      if let userInfo = pendingNotificationTap {
        apnsChannel?.invokeMethod("onNotificationTap", arguments: sanitize(userInfo))
        pendingNotificationTap = nil
      }
    }
  }

  // MARK: - APNs delegate

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    if let channel = apnsChannel {
      channel.invokeMethod("onDeviceToken", arguments: token)
    } else {
      // Engine not yet initialized — buffer until didInitializeImplicitFlutterEngine.
      pendingDeviceToken = token
    }
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    apnsChannel?.invokeMethod("onDeviceTokenError", arguments: error.localizedDescription)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // MARK: - UNUserNotificationCenterDelegate

  // User tapped a notification (either while the app was running or via cold
  // start). Forward the userInfo to Dart so account-aware routing can pick
  // the matching account before navigating to the notifications tab.
  //
  // Flutter の各種プラグイン（flutter_local_notifications 等）は同じデリゲート
  // メソッドを swizzling で拾うため、super を呼んでチェーンを維持する。
  // completionHandler は super に委ねて一度だけ呼ばせる。
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    if let channel = apnsChannel {
      channel.invokeMethod("onNotificationTap", arguments: sanitize(userInfo))
    } else {
      // Buffer until the Flutter engine finishes initializing.
      pendingNotificationTap = userInfo
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  // UNNotificationResponse.userInfo is [AnyHashable: Any], but the Flutter
  // method channel marshaller only handles [String: Any]. Convert keys and
  // drop non-string-keyed entries (there shouldn't be any, but be defensive).
  private func sanitize(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in userInfo {
      if let k = key as? String {
        out[k] = value
      }
    }
    return out
  }
}
