import '../../model/gallery_post.dart';
import '../../model/timeline_query.dart';

abstract mixin class GallerySupport {
  Future<List<GalleryPost>> getGalleryPosts({TimelineQuery? query});
  Future<List<GalleryPost>> getUserGalleryPosts(
    String userId, {
    TimelineQuery? query,
  });

  /// 投稿 1 つを id で引く (#1150)。デッキで読み戻したギャラリーのカラムが使う。
  Future<GalleryPost> getGalleryPostById(String postId);
}
