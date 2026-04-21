import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var apnsChannel: FlutterMethodChannel?
  private var pendingDeviceToken: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Request APNs device token. This does not trigger a user-facing
    // permission dialog; it only asks iOS for the token.
    application.registerForRemoteNotifications()

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
}
