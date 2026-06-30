import 'notification.dart';
import 'timeline_response.dart';

/// Response from a notification fetch, including pagination metadata.
///
/// Mirrors [TimelineResponse]: malformed notifications are skipped during
/// conversion (#741), so the post-skip list length cannot be used to judge
/// whether more pages exist. [rawCount] / [rawLastId] preserve the pre-filter
/// server signal so pagination keeps advancing past skipped items (#777).
class NotificationResponse {
  final List<Notification> notifications;

  /// The number of items returned by the server before any client-side
  /// filtering (e.g. skipping malformed notifications during conversion).
  final int rawCount;

  /// The ID of the last (oldest) item in the raw server response, before any
  /// client-side filtering. Used to advance the pagination cursor even when
  /// some or all items in a page are skipped.
  final String? rawLastId;

  /// Notifications that failed conversion from the server's raw format.
  final List<SkippedPost> skippedPosts;

  const NotificationResponse({
    required this.notifications,
    required this.rawCount,
    this.rawLastId,
    this.skippedPosts = const [],
  });
}
