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

  /// 自分の投稿への引用を撤回する (#1213)。
  ///
  /// [quotedPostId] は引用された側（自分の投稿）、[quotingPostId] は引用した側。
  /// 戻り値は、引用が外れたあとの**引用した側**の投稿。
  ///
  /// ⚠ **引用された側の道具。**相手のサーバーの管理者を待たずに、自分で外せる。
  /// ⚠ 取り消せない（撤回した引用を、引用された側から戻す口は無い）。
  Future<Post> revokeQuote({
    required String quotedPostId,
    required String quotingPostId,
  });

  /// 投稿したあとに、引用の許可を変える (#1213)。戻り値は変えたあとの投稿。
  ///
  /// [policy] は投稿時の `quote_approval_policy` と同じ語彙（`public` /
  /// `followers` / `nobody`）。
  Future<Post> setQuoteApprovalPolicy(String postId, String policy);
}
