import '../../model/timeline_query.dart';
import '../../model/user.dart';
import '../../model/user_relationship.dart';

abstract mixin class FollowSupport {
  Future<UserRelationship> getRelationship(String userId);
  Future<void> followUser(String id);
  Future<void> unfollowUser(String id);
  Future<void> muteUser(String id, {Duration? duration});
  Future<void> unmuteUser(String id);
  Future<void> blockUser(String id);
  Future<void> unblockUser(String id);
  Future<({List<User> users, String? nextCursor})> getFollowers(
    String userId, {
    TimelineQuery? query,
  });
  Future<({List<User> users, String? nextCursor})> getFollowing(
    String userId, {
    TimelineQuery? query,
  });
}
