import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class BookmarkSupport {
  Future<Post> bookmarkPost(String id);
  Future<Post> unbookmarkPost(String id);
  Future<List<Post>> getBookmarks({TimelineQuery? query});
}
