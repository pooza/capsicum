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

  /// ブロック中のユーザー一覧 (#1039)。
  ///
  /// ⚠ **`blockUser` の裏返しが無いと、自分が誰をブロックしているか確認できない。**
  Future<({List<User> users, String? nextCursor})> getBlockedUsers({
    TimelineQuery? query,
  });

  /// ミュート中のユーザー一覧 (#1039)。
  ///
  /// ⚠⚠ **これが無いと解除の導線が構造的に塞がる。**ミュートは「相手が TL から
  /// 出てこなくなる」操作なので、解除したくなったときに相手のプロフィールへ
  /// 辿り着く手段が残らない。うろ覚えだと詰む。
  Future<({List<User> users, String? nextCursor})> getMutedUsers({
    TimelineQuery? query,
  });
}
