import 'post.dart';

/// Response from a timeline fetch, including pagination metadata.
class TimelineResponse {
  final List<Post> posts;

  /// The number of items returned by the server before any client-side
  /// filtering (e.g. skipping malformed statuses during conversion).
  final int rawCount;

  const TimelineResponse({required this.posts, required this.rawCount});
}
