import AppKit
import FlutterMacOS
import UserNotifications

/// 起動中の二重通知 dedup (#674)。
///
/// アプリ起動中は同じ通知イベントが 2 経路で届きうる:
/// - #569: WebSocket 通知ストリーム → flutter_local_notifications のローカル通知
/// - #468: APNs (capsicum-relay 経由) → NSE (#673) が復号して表示
///
/// 本 plugin は UNUserNotificationCenter delegate を proxy で包み、remote push
/// の willPresent を `account|notificationId` キーで Dart 側 dispatcher の
/// 既出集合と突き合わせて後着を黙殺する。flutter_local_notifications が delegate
/// を保持する判断 (#569) は崩さず、FLN 由来の通知・タップ応答はすべて元 delegate
/// へ素通しする。
///
/// 方向別の動作:
/// - WebSocket 先着 → Dart が `addEmitted` でキーを先に登録 → APNs 側 willPresent
///   が黙殺 (`completionHandler([])`)
/// - APNs 先着 → willPresent がキーを登録 + `onRemotePresented` で Dart へ通知 →
///   WebSocket 側 dispatcher が emit をスキップ
///
/// 制約 (内部ベータで実測確認する):
/// - willPresent はアプリが foreground のときしか呼ばれない。macOS で
///   「起動中だが非アクティブ」のときに呼ばれるかは文書上確定しないため、
///   呼び出し状況を NSLog で残し内部ベータで確認する。呼ばれないケースでは
///   APNs banner は OS 既定で表示され、本 dedup は WebSocket 側 (Dart) の
///   スキップのみ効く。
/// - NSE 復号に失敗した generic 通知は stamp (#673) が無く dedup 不能。従来の
///   FLN delegate は非 FLN 通知の completionHandler を呼ばず foreground 表示を
///   事実上握りつぶしていたため、現状維持として黙殺する (重複より取りこぼしの
///   方が安全、の例外。generic は WebSocket 側が同イベントをリッチ文面で出す
///   見込みが高い)。
class NotificationDedupPlugin: NSObject, UNUserNotificationCenterDelegate {
  /// Dart 側 DesktopNotificationDispatcher と同じ上限。超えたら全消しして
  /// 作り直す (LRU は不要。取りこぼしても「多重表示の方が落とすより安全」)。
  private static let maxTrackedKeys = 500

  private let channel: FlutterMethodChannel
  /// flutter_local_notifications の plugin instance。FLN 由来の通知と
  /// タップ応答 (didReceive) はすべてここへ委譲する。
  private let wrapped: UNUserNotificationCenterDelegate

  private var seenKeys = Set<String>()

  private init(
    channel: FlutterMethodChannel,
    wrapped: UNUserNotificationCenterDelegate
  ) {
    self.channel = channel
    self.wrapped = wrapped
    super.init()
  }

  /// 現在の UNUserNotificationCenter delegate (= flutter_local_notifications、
  /// plugin 登録時に設定済み) を包んで差し替える。FLN が delegate を持たない
  /// 状態 (想定外) では何もしない。
  ///
  /// 戻り値は install 済みインスタンス (retain 用)。UNUserNotificationCenter.delegate
  /// は weak のため、呼び出し側 (MainFlutterWindow) が強参照を保持すること。
  static func install(binaryMessenger: FlutterBinaryMessenger) -> NotificationDedupPlugin? {
    let center = UNUserNotificationCenter.current()
    guard let current = center.delegate else {
      NSLog("capsicum: dedup: no existing UNUserNotificationCenter delegate, skip install")
      return nil
    }
    let channel = FlutterMethodChannel(
      name: "net.shrieker.capsicum/notification_dedup",
      binaryMessenger: binaryMessenger
    )
    let plugin = NotificationDedupPlugin(channel: channel, wrapped: current)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "addEmitted":
        if let key = call.arguments as? String {
          plugin.remember(key)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    center.delegate = plugin
    return plugin
  }

  private func remember(_ key: String) {
    if seenKeys.count >= Self.maxTrackedKeys {
      seenKeys.removeAll()
    }
    seenKeys.insert(key)
  }

  /// 非 FLN 通知 = APNs remote push (relay は userInfo に account を必ず載せる)。
  /// FLN 判定は flutter_local_notifications の isAFlutterLocalNotification と
  /// 同じキー集合で行う。
  private func isFlutterLocalNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    return userInfo["presentAlert"] != nil && userInfo["presentSound"] != nil
      && userInfo["presentBadge"] != nil && userInfo["payload"] != nil
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    if isFlutterLocalNotification(userInfo) {
      // FLN のローカル通知 (#569 経由を含む) は元 delegate の表示判定に委ねる。
      wrapped.userNotificationCenter?(
        center, willPresent: notification, withCompletionHandler: completionHandler)
      return
    }
    let account = userInfo["account"] as? String
    let notificationId = userInfo["capsicum_notification_id"] as? String
    guard let account = account, let notificationId = notificationId else {
      // stamp が無い remote (NSE 復号失敗の generic 等)。dedup 不能のため黙殺
      // (クラス docs 参照。従来 FLN delegate が completionHandler を呼ばず
      // foreground 表示されていなかった挙動の維持)。
      NSLog("capsicum: dedup: willPresent without id stamp, suppress (active=\(NSApp.isActive))")
      completionHandler([])
      return
    }
    let key = "\(account)|\(notificationId)"
    if seenKeys.contains(key) {
      // WebSocket 側が先着済み。後着の APNs banner を黙殺する。
      NSLog("capsicum: dedup: suppress duplicate remote (active=\(NSApp.isActive))")
      completionHandler([])
      return
    }
    // APNs 先着。表示しつつ Dart 側 dispatcher に既出を伝える。
    remember(key)
    channel.invokeMethod("onRemotePresented", arguments: key)
    NSLog("capsicum: dedup: present remote first (active=\(NSApp.isActive))")
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // タップ応答は dedup の対象外。FLN 由来は元 delegate が画面遷移へ配線し、
    // remote 由来は従来どおり何もしない (タップ導線は #440 系の別課題)。
    if isFlutterLocalNotification(response.notification.request.content.userInfo) {
      wrapped.userNotificationCenter?(
        center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }
    completionHandler()
  }
}
