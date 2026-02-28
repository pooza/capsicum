import '../../model/user.dart';

abstract mixin class FollowSupport {
  Future<void> followUser(String id);
  Future<void> unfollowUser(String id);
  Future<List<User>> getFollowers(String userId);
  Future<List<User>> getFollowing(String userId);
}
