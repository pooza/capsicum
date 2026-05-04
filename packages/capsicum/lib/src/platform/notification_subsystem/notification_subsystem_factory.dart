import 'flutter_local_notification_subsystem.dart';
import 'notification_subsystem.dart';

/// プラットフォームに応じた [NotificationSubsystem] 実装を生成する。
/// flutter_local_notifications がデスクトップを含む全プラットフォームを
/// カバーするため、現状は単一実装。将来 native ベースの実装に差し替えたい
/// 場合の差し込み口として factory を分離してある。
NotificationSubsystem createNotificationSubsystem() {
  return FlutterLocalNotificationSubsystem();
}
