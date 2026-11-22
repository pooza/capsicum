import '../../model/gallery_post.dart';
import '../../model/timeline_query.dart';

abstract mixin class GallerySupport {
  /// 注目のギャラリー投稿（Misskey の `gallery/featured`）。
  Future<List<GalleryPost>> getGalleryPosts({TimelineQuery? query});

  /// 新着のギャラリー投稿 (#1053)。Misskey の `gallery/posts`（新しい順・
  /// `untilId` でページを送る）。
  Future<List<GalleryPost>> getRecentGalleryPosts({
    TimelineQuery? query,
  }) async => const [];

  Future<List<GalleryPost>> getUserGalleryPosts(
    String userId, {
    TimelineQuery? query,
  });

  /// 投稿 1 つを id で引く (#1150)。デッキで読み戻したギャラリーのカラムが使う。
  Future<GalleryPost> getGalleryPostById(String postId);

  /// いいねする (#1053)。`write:gallery-likes` スコープが要る（旧トークンは
  /// 再ログインまで 403）。自分の投稿は `YOUR_POST`、いいね済みは
  /// `ALREADY_LIKED` で断られる。
  Future<void> likeGalleryPost(String postId) async {}

  /// いいねを取り消す (#1053)。いいねしていなければ `NOT_LIKED`。
  Future<void> unlikeGalleryPost(String postId) async {}
}
