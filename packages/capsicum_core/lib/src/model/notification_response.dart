import 'notification.dart';
import 'timeline_response.dart';

/// Response from a notification fetch, including pagination metadata.
///
/// Mirrors [TimelineResponse]: malformed notifications are skipped during
/// conversion (#741), so the post-skip list length cannot be used to judge
/// whether more pages exist. [rawCount] / [rawLastId] preserve the pre-filter
/// server signal so pagination keeps advancing past skipped items (#777).
class NotificationResponse {
  final List<Notification> notifications;

  /// The number of items returned by the server before any client-side
  /// filtering (e.g. skipping malformed notifications during conversion).
  final int rawCount;

  /// The ID of the last (oldest) item in the raw server response, before any
  /// client-side filtering. Used to advance the pagination cursor even when
  /// some or all items in a page are skipped.
  final String? rawLastId;

  /// Notifications that failed conversion from the server's raw format.
  final List<SkippedPost> skippedPosts;

  /// さらに古いページがありうるか。アダプタが判断できるときだけ非 null (#1048)。
  ///
  /// ⚠⚠ **グループ化した取得では [rawCount] から判断できない。**サーバーの
  /// `limit` は**通知の件数**に掛かるのに、返ってくるのは**グループの件数**なので、
  /// 「同じ投稿への 20 件のリアクション」は `limit: 20` に対して 1 グループで
  /// 返る。`rawCount >= limit` で判定すると**そこで打ち切って以降が読めなくなる**。
  /// グループ化する経路はここへ「ページが空でなければ続きがありうる」を入れる
  /// （最終ページの次に空の 1 回が走るのは許容する）。
  final bool? hasMore;

  /// 種別の絞り込みを、サーバーではなく手元で掛けたページか (#1251)。
  ///
  /// サーバーが除外の指定を断った（古い Misskey は新しい種別を知らない）回に
  /// 立つ。⚠ **このページは `notifications` が `rawCount` より大きく減りうる**
  /// —— 20 件取って数件しか残らないページが続くので、呼び出し側は追加読み込みを
  /// 連打しないよう間を置く。
  final bool filteredLocally;

  const NotificationResponse({
    required this.notifications,
    required this.rawCount,
    this.rawLastId,
    this.skippedPosts = const [],
    this.hasMore,
    this.filteredLocally = false,
  });
}
