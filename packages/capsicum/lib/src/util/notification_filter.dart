import 'package:capsicum_core/capsicum_core.dart';

/// フィルターを掛ける通知の種別 (#1289)。**他人の投稿が主役の通知だけ。**
///
/// Mastodon Web（`actions/notification_groups.ts` / `actions/notifications.js`）と
/// 同じ線: メンション・引用・編集・購読中の新規投稿。⚠ **お気に入り・ブースト・
/// リアクション・投票の通知には掛けない** —— 付いている投稿は自分の投稿で、
/// Mastodon は自分の投稿にもフィルターの結果を載せて返すため、掛けると自分の
/// 投稿のキーワードで反応の通知が消える。
const _filteredNotificationTypes = {
  NotificationType.mention,
  NotificationType.quote,
  NotificationType.update,
  NotificationType.quotedUpdate,
  NotificationType.newPost,
};

/// [n] に、通知の適用先（`notifications`）でかかるフィルター。当たらなければ null。
FilterVerdict? notificationFilterVerdict(Notification n) {
  if (!_filteredNotificationTypes.contains(n.type)) return null;
  return n.post?.filterVerdictFor(FilterContext.notifications);
}

/// 通知の一覧から、通知の適用先で hide のものを落とす (#1289)。
///
/// ⚠ サーバーは通知の配送（`NotifyService`）でキーワードのフィルターを見ない
/// ので、落とさないと「通知だけ伏せる」フィルターが素通りする。
List<Notification> dropFilteredNotifications(
  List<Notification> notifications,
) => [
  for (final n in notifications)
    if (notificationFilterVerdict(n)?.action != FilterAction.hide) n,
];
