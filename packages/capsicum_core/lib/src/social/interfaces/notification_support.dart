import '../../model/notification.dart';

abstract mixin class NotificationSupport {
  Future<List<Notification>> getNotifications();
  Future<void> clearAllNotifications();
}
