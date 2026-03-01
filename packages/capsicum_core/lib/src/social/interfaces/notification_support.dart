import '../../model/notification.dart';
import '../../model/timeline_query.dart';

abstract mixin class NotificationSupport {
  Future<List<Notification>> getNotifications({TimelineQuery? query});
  Future<void> clearAllNotifications();
}
