import '../../model/post.dart';
import '../../model/timeline_query.dart';

/// その投稿を引用している投稿を一覧する (#1072)。
///
/// ⚠ **capsicum は引用数を表示しているのに、そこから引用元へ行けなかった。**
/// ブースト一覧・お気に入り一覧は投稿単位で実装済みなのに引用だけ数字止まりで、
/// 数字が出ている以上「押せば見られる」と期待されるが押せない、という形。
///
/// ⚠ **Mastodon 固有。**このインターフェースを持たないアダプターでは、
/// 引用数のタップを導線として出さない（`adapter is QuoteSupport` で判定する）。
abstract mixin class QuoteSupport {
  /// ⚠ **カーソルは投稿 id ではない。**`Link` ヘッダ由来の値をそのまま
  /// 次の [TimelineQuery.maxId] へ渡す。
  Future<({List<Post> posts, String? nextCursor})> getQuotesOf(
    String postId, {
    TimelineQuery? query,
  });
}
