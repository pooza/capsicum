import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class FavoriteSupport {
  Future<Post> favoritePost(String id);
  Future<Post> unfavoritePost(String id);

  /// お気に入りに入れた投稿の一覧 (#1071)。
  ///
  /// ⚠ **「付ける」側だけあって「見る」側が無い**状態だった。同じ「あとで
  /// 見る」系でブックマークにだけ一覧があるという非対称になっていた。
  ///
  /// ⚠ **Mastodon 固有。**Misskey の「お気に入り」は意味的にブックマーク相当で、
  /// capsicum は既に `/bookmarks` へ寄せてある（docs/CLAUDE.md の機能マッピング
  /// 表）。`FavoriteSupport` 自体を Misskey adapter が持たない（リアクションで
  /// 代替）ので、こちらに実装は要らない。
  /// ⚠⚠ **ページングのカーソルは投稿 id ではない。**Mastodon の
  /// `GET /api/v1/favourites` は**お気に入りレコードの内部 id** で切るので、
  /// 一覧の最後の `Post.id` を `max_id` に渡すと**ページが飛ぶ**。`Link`
  /// ヘッダから取った値をそのまま次の `query.maxId` へ渡すこと。
  Future<({List<Post> posts, String? nextCursor})> getFavorites({
    TimelineQuery? query,
  });
}
