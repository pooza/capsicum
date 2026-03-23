import '../../model/scheduled_post.dart';

abstract mixin class ScheduleSupport {
  Future<List<ScheduledPost>> getScheduledPosts();
  Future<void> cancelScheduledPost(String id);
}
