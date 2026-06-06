import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../constants.dart';
import 'notification_subsystem.dart';

/// 全プラットフォーム共通の flutter_local_notifications ベース実装。
///
/// flutter_local_notifications は Android / iOS / macOS / Linux / Windows を
/// 一通りカバーしているため、抽象層では単一実装で済ませてプラットフォーム
/// 差は内部の Details 構築で吸収する。Linux は libnotify、Windows は
/// Toast XML を使う。アクションボタン等は category マトリクス（将来拡張）で
/// 表現する。
class FlutterLocalNotificationSubsystem implements NotificationSubsystem {
  static const _androidChannelId = 'capsicum_push';
  static const _androidChannelName = 'プッシュ通知';

  final FlutterLocalNotificationsPlugin _plugin;

  FlutterLocalNotificationSubsystem({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  @override
  Future<void> initialize({void Function(String? payload)? onTap}) async {
    try {
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      // iOS は APNs から token を取得して push 経路が成立しているため
      // 通知許可を要求する。
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      // macOS は AppDelegate 側で registerForRemoteNotifications を未配線で
      // push 経路が成立していないため、許可ダイアログを出してもユーザーが
      // 許可しても何も来ない (#404)。push を配線するまでは許可要求を抑制し、
      // plugin の初期化だけ成立させる。macOS 設定 (DarwinInitializationSettings)
      // 自体は渡さないと macOS で plugin.initialize が失敗するので残す (#327)。
      const macOSSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const linuxSettings = LinuxInitializationSettings(
        defaultActionName: '開く',
      );
      // Windows は flutter_local_notifications v19 で対応開始、v21 federated
      // package (flutter_local_notifications_windows) で MSIX に同梱される
      // (#423)。
      // - appName: アクションセンタ上での通知グルーピング表示名
      // - appUserModelId / guid: pubspec.yaml の msix_config と完全一致が必須。
      //   定数は constants.dart の WindowsIdentifiers に集約済み (#554)。
      const windowsSettings = WindowsInitializationSettings(
        appName: AppConstants.appName,
        appUserModelId: WindowsIdentifiers.appUserModelId,
        guid: WindowsIdentifiers.toastActivatorClsid,
      );
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
          macOS: macOSSettings,
          linux: linuxSettings,
          windows: windowsSettings,
        ),
        onDidReceiveNotificationResponse: onTap == null
            ? null
            : (response) => onTap(response.payload),
      );

      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.requestNotificationsPermission();
    } catch (e, st) {
      debugPrint('capsicum: notification: init failed: $e');
      // 初期化失敗は通知配信が完全に止まる致命的状態だが、UI 起動経路は
      // 止めない（observability 故障で本体を落とさない方針）。Sentry に
      // 上げて気付ける状態を確保する。bg isolate / Sentry 未初期化経路でも
      // 失敗が UI を巻き込まないよう更に try で包む。
      try {
        await Sentry.captureException(
          e,
          stackTrace: st,
          hint: Hint.withMap({'subsystem': 'notification'}),
        );
      } catch (_) {
        // ignore
      }
    }
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    NotificationCategory category = NotificationCategory.message,
  }) {
    const androidDetails = AndroidNotificationDetails(
      _androidChannelId,
      _androidChannelName,
      importance: Importance.high,
      priority: Priority.high,
    );
    // iOS は従来どおり（前面挙動は既存のまま）。
    const iosDetails = DarwinNotificationDetails();
    // macOS (#569) は「アプリ起動中」にデスクトップ通知を出すのが主目的なので、
    // アプリが最前面でもバナーを表示させる。macOS は既定で「最前面アプリ自身が
    // 出した通知」のバナーを抑制するため、前面提示を明示的に許可する。
    const macosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
    );
    const linuxDetails = LinuxNotificationDetails();
    const windowsDetails = WindowsNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: macosDetails,
      linux: linuxDetails,
      windows: windowsDetails,
    );
    return _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  @override
  Future<bool> requestPermission() async {
    final iosPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosPlugin != null) {
      return await iosPlugin.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    final macOSPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    if (macOSPlugin != null) {
      // macOS は AppDelegate で registerForRemoteNotifications を未配線で
      // push 経路が成立しないため、許可を取っても何も届かない (#404)。
      // push を配線したタイミングで本来の requestPermissions を呼ぶよう
      // 戻す。それまでは許可ダイアログを出さず false を返す。
      return false;
    }
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin != null) {
      return await androidPlugin.requestNotificationsPermission() ?? false;
    }
    // Linux / Windows は OS 設定に従う。
    return true;
  }
}
