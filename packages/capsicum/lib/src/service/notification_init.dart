import '../platform/notification_subsystem/notification_subsystem.dart';
import '../platform/notification_subsystem/notification_subsystem_factory.dart';

/// アプリ全体で共有するローカル通知サブシステムの singleton。
///
/// Riverpod 経由 (`notificationSubsystemProvider`) でも同じ実装が見られるが、
/// バックグラウンド isolate（FCM の `_firebaseBackgroundMessageHandler` 等）と
/// `runApp` より前のブートストラップ経路では provider scope が無いため、
/// この top-level 変数経由で参照する。両経路で同一インスタンスが返るよう、
/// provider 側もこの変数をそのまま返す。
final NotificationSubsystem notificationSubsystem =
    createNotificationSubsystem();
