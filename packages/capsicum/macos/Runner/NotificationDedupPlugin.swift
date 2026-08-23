import AppKit
import FlutterMacOS
import UserNotifications

/// 上限に達したら**最古から押し出す**キー集合 (#983)。
///
/// Dart 側 `service/bounded_key_set.dart` の `BoundedKeySet` と同じ意味を
/// 持たせる。Swift の `Set` は挿入順を保たないので、順序は配列で別に持つ。
/// ⚠ **参照先は #982 で移設済み** — `desktop_notification_dispatcher.dart` の
/// `_BoundedKeySet` はもう無い（Windows 側の doc は追随済みで、ここだけ
/// 取り残されていた・#1012）。
///
/// ## なぜ全消しではいけないか
///
/// #960 で「全消しから FIFO 追い出しへ」を入れたとき、置き換えたのは Dart 側の
/// 2 集合だけで、こちらは全消しのまま残っていた。ところが**効き方が違う**:
///
/// - Dart 側の 2 集合は「もう出したか」の記録。取りこぼしても多重表示になるだけ
/// - こちらは `willPresent` で**抑止するかどうかを決める判定そのもの**。全消しの
///   直後に遅れて届いた APNs banner は「未出」と判定されて表示されるので、
///   **#674 が防いでいる二重表示がそのまま復活する**
///
/// 500 件は実況運用のセッションで到達しうる。
///
/// ⚠ **メインスレッド専用。** 触るのは `willPresent` デリゲートと
/// `FlutterMethodChannel` のハンドラだけで、どちらもプラットフォーム（メイン）
/// スレッドで走る。旧実装（`Set` 1 本）と違い `keys` と `order` の 2 つを整合
/// させる構造なので、別キューから触ると壊れ方が悪い。
struct BoundedKeySet {
  private let name: String
  private let maxSize: Int
  private var keys = Set<String>()
  /// 挿入順。`keys` と常に同じ要素を持つ。
  private var order = [String]()
  /// 上限超過で押し出した累計件数 (観測用)。
  private(set) var dropped = 0

  init(_ name: String, _ maxSize: Int) {
    self.name = name
    self.maxSize = maxSize
  }

  func contains(_ key: String) -> Bool { keys.contains(key) }

  /// [key] を追加し、新規なら true を返す (`Set.add` と同じ意味)。
  ///
  /// ⚠ **既出キーでは順序を動かさない。** Dart の `LinkedHashSet` が再挿入で
  /// 位置を変えないのに合わせる (LRU ではなく FIFO)。
  @discardableResult
  mutating func add(_ key: String) -> Bool {
    guard keys.insert(key).inserted else { return false }
    order.append(key)
    var evicted = 0
    while order.count > maxSize {
      keys.remove(order.removeFirst())
      dropped += 1
      evicted += 1
    }
    if evicted > 0 {
      NSLog(
        "capsicum: dedup: \"\(name)\" evicted \(evicted) oldest "
          + "(size=\(order.count)/\(maxSize), total_dropped=\(dropped))")
    }
    return true
  }
}

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
/// 制約 (2026-06-12 内部ベータ 104/105 で実測確定):
/// - willPresent はアプリが非アクティブ (背面) のときは呼ばれない。
///   そのケースの APNs banner は OS 既定で表示される。
/// - macOS は NSE (#673) に didReceive を渡さず約 2 秒で kill するため
///   (「Extension will be killed due to sluggish startup」、OS 側の実装欠落)、
///   APNs 通知は常に stamp 無しの generic 文面で届く。
///
/// このため willPresent ベースの dedup は前面でしか効かず、背面では generic
/// banner が重複表示される。後始末として Dart 側 DeliveredPushCleaner が
/// [getDeliveredRemotes] で配信済み remote を取得 → 暗号化 body を main app の
/// 鍵で復号して notificationId を特定 → WebSocket 側の既出キーと一致したものを
/// [removeDelivered] で通知センターから削除する。掃除のトリガは
/// AppDelegate の didReceiveRemoteNotification → [notifyRemoteArrived]
/// (APNs 後着 = 主経路) と、WebSocket emit 直後 (APNs 先着の逆順) の 2 つ。
///
/// - NSE 復号に失敗した generic 通知は stamp (#673) が無く willPresent では
///   dedup 不能。従来の FLN delegate は非 FLN 通知の completionHandler を
///   呼ばず foreground 表示を事実上握りつぶしていたため、現状維持として
///   黙殺する (重複より取りこぼしの方が安全、の例外。generic は WebSocket
///   側が同イベントをリッチ文面で出す見込みが高い)。
class NotificationDedupPlugin: NSObject, UNUserNotificationCenterDelegate {
  /// Dart 側 DesktopNotificationDispatcher と同じ上限。
  private static let maxTrackedKeys = 500

  private let channel: FlutterMethodChannel
  /// flutter_local_notifications の plugin instance。FLN 由来の通知と
  /// タップ応答 (didReceive) はすべてここへ委譲する。
  private let wrapped: UNUserNotificationCenterDelegate

  /// ⚠ **全消しにしない** (#983)。理由は [BoundedKeySet] の docs。
  private var seenKeys = BoundedKeySet("seen", NotificationDedupPlugin.maxTrackedKeys)

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
      case "getDeliveredRemotes":
        plugin.collectDeliveredRemotes(result)
      case "removeDelivered":
        if let ids = call.arguments as? [String], !ids.isEmpty {
          UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ids)
          NSLog("capsicum: dedup: removed \(ids.count) delivered remote(s)")
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    center.delegate = plugin
    return plugin
  }

  /// AppDelegate の didReceiveRemoteNotification から呼ばれる (#673 後始末)。
  /// アプリ起動中に APNs が届いた合図を Dart 側 DeliveredPushCleaner へ流し、
  /// 配信済み generic 通知の掃除をトリガする。
  func notifyRemoteArrived() {
    channel.invokeMethod("onRemoteArrived", arguments: nil)
  }

  /// 配信済み通知のうち APNs remote 由来 (非 FLN かつ account 付き) を
  /// Dart 側へ返す。復号は鍵を持つ Dart 側の責務のため、ここでは userInfo の
  /// 必要キーをそのまま渡すだけにする。
  private func collectDeliveredRemotes(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
      let remotes: [[String: Any]] = notifications.compactMap { notification in
        let userInfo = notification.request.content.userInfo
        if self.isFlutterLocalNotification(userInfo) { return nil }
        guard let account = userInfo["account"] as? String else { return nil }
        var entry: [String: Any] = [
          "identifier": notification.request.identifier,
          "account": account,
        ]
        if let body = userInfo["body"] as? String { entry["body"] = body }
        if let encoding = userInfo["encoding"] as? String {
          entry["encoding"] = encoding
        }
        // NSE が動く環境 (OS 側が直った場合) では stamp をそのまま使えるよう
        // 復号不要の手がかりも渡す。
        if let stamped = userInfo["capsicum_notification_id"] as? String {
          entry["stampedId"] = stamped
        }
        return entry
      }
      // FlutterMethodChannel の result はプラットフォームスレッドで呼ぶ。
      DispatchQueue.main.async { result(remotes) }
    }
  }

  private func remember(_ key: String) {
    seenKeys.add(key)
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
