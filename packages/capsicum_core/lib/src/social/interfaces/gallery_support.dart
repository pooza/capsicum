import '../../model/gallery_post.dart';
import '../../model/timeline_query.dart';

abstract mixin class GallerySupport {
  Future<List<GalleryPost>> getGalleryPosts({TimelineQuery? query});
  Future<List<GalleryPost>> getUserGalleryPosts(
    String userId, {
    TimelineQuery? query,
  });
}
