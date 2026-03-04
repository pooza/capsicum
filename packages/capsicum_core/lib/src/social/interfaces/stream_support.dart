import '../../model/post.dart';
import '../../model/timeline_type.dart';

abstract mixin class StreamSupport {
  /// Returns a stream of new posts for the given timeline type.
  Stream<Post> streamTimeline(TimelineType type);

  /// Closes the current streaming connection.
  void disposeStream();
}
