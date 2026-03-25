import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class HashtagSupport {
  Future<bool> isFollowingHashtag(String hashtag);
  Future<void> followHashtag(String hashtag);
  Future<void> unfollowHashtag(String hashtag);
  Future<List<Post>> getPostsByHashtag(String hashtag, {TimelineQuery? query});
}
