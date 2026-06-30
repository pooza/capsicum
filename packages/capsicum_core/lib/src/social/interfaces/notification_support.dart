import '../../model/notification_response.dart';
import '../../model/timeline_query.dart';

abstract mixin class NotificationSupport {
  Future<NotificationResponse> getNotifications({TimelineQuery? query});
  Future<void> clearAllNotifications();
}
