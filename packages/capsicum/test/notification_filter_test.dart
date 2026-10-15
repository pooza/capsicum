import 'package:capsicum/src/util/notification_filter.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1289: 通知にフィルターを掛ける。
///
/// ⚠ サーバーは通知の配送でキーワードのフィルターを見ないので、クライアントが
/// 落とさないと「通知だけ伏せる」フィルターが素通りする。
void main() {
  Post post(List<FilterMatch> matches) => Post(
    id: 'p',
    postedAt: DateTime.utc(2026, 10, 15),
    author: const User(id: 'u', username: 'someone'),
    content: 'ほげ',
    filterMatches: matches,
  );

  Notification notification(
    String id,
    NotificationType type,
    List<FilterMatch> matches,
  ) => Notification(
    id: id,
    type: type,
    createdAt: DateTime.utc(2026, 10, 15),
    user: const User(id: 'u', username: 'someone'),
    post: post(matches),
  );

  const notificationsHide = [
    FilterMatch(
      action: FilterAction.hide,
      contexts: {FilterContext.notifications},
    ),
  ];
  const homeHide = [
    FilterMatch(action: FilterAction.hide, contexts: {FilterContext.home}),
  ];

  test('⚠⚠ 通知に効く hide のメンションは落とす', () {
    final kept = dropFilteredNotifications([
      notification('1', NotificationType.mention, notificationsHide),
      notification('2', NotificationType.mention, const []),
    ]);
    expect(kept.map((n) => n.id), ['2']);
  });

  test('⚠ ホームだけに効く hide は、通知では落とさない', () {
    final kept = dropFilteredNotifications([
      notification('1', NotificationType.mention, homeHide),
    ]);
    expect(kept.map((n) => n.id), ['1']);
  });

  // ⚠⚠ お気に入り・ブーストの通知の投稿は自分の投稿。Mastodon は自分の投稿にも
  // フィルターの結果を載せるので、掛けると自分のキーワードで反応の通知が消える。
  test('⚠⚠ お気に入り・ブースト・リアクション・投票の通知には掛けない', () {
    final kept = dropFilteredNotifications([
      notification('1', NotificationType.favourite, notificationsHide),
      notification('2', NotificationType.reblog, notificationsHide),
      notification('3', NotificationType.reaction, notificationsHide),
      notification('4', NotificationType.poll, notificationsHide),
    ]);
    expect(kept.map((n) => n.id), ['1', '2', '3', '4']);
  });

  test('引用・編集・購読中の新規投稿には掛ける（Mastodon Web と同じ）', () {
    final kept = dropFilteredNotifications([
      notification('1', NotificationType.quote, notificationsHide),
      notification('2', NotificationType.update, notificationsHide),
      notification('3', NotificationType.quotedUpdate, notificationsHide),
      notification('4', NotificationType.newPost, notificationsHide),
    ]);
    expect(kept, isEmpty);
  });

  test('warn は落とさず、判定として返す（タイルが本文を畳む）', () {
    const warn = [
      FilterMatch(
        action: FilterAction.warn,
        title: '実況',
        contexts: {FilterContext.notifications},
      ),
    ];
    final n = notification('1', NotificationType.mention, warn);
    expect(dropFilteredNotifications([n]), [n]);
    expect(notificationFilterVerdict(n)?.title, '実況');
  });
}
