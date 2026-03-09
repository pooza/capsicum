import '../../model/timeline_query.dart';
import '../../model/user.dart';

abstract mixin class FollowSupport {
  Future<void> followUser(String id);
  Future<void> unfollowUser(String id);
  Future<List<User>> getFollowers(String userId, {TimelineQuery? query});
  Future<List<User>> getFollowing(String userId, {TimelineQuery? query});
}
