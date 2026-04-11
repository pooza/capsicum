import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register the BGTaskScheduler launch handler before the app finishes
    // launching. iOS requires all identifiers in BGTaskSchedulerPermittedIdentifiers
    // to have a registered handler at launch time; otherwise submitting a
    // matching task crashes with NSInternalInconsistencyException.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "jp.co.b-shock.capsicum.iOSBackgroundAppRefresh",
      frequency: nil
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShareIntentPlugin") {
      ShareIntentPlugin.register(with: registrar)
    }
  }
}
