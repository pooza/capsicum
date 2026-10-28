import 'package:capsicum_core/capsicum_core.dart';

import '../model/account.dart';
import '../service/announcement_subscription_service.dart';

// お知らせを通知のタイムラインに含める (#1308・2026-10-27 pooza 判断)。
//
// Mastodon / Misskey の通知にはお知らせは無いが、capsicum ではお知らせが
// プッシュ通知の対象（#477 / #919）なので、通知の一覧に並べる。
//
// - 含めるかは、お知らせのプッシュ通知のトグルに連動する。トグルが無いところ
//   （Linux・お知らせのプッシュに対応していないサーバー）では常に含める
// - 並べる位置は公開日時。編集されても動かさず「編集済み」の印だけ付ける
// - 既読には触らない。通知を見てもお知らせは既読にせず、未読数にも足さない
// - 押すとお知らせの画面を開く
// - 通知の種類の絞り込みでは「お知らせ」を 1 つの種類として扱う（サーバーの
//   通知ではないので、絞り込みは手元で掛ける）
// - 反映は次の再読み込みでよい（前面に居続けている間の即時の反映は #910）

/// お知らせ 1 件を通知の 1 行にする。
///
/// ⚠ id はストリーミングの経路（`notification_streaming.dart`）と同じ
/// `announcement:<id>`。⚠⚠ **サーバーの通知の id ではない**ので、既読位置や
/// カーソルに使わない（[firstServerNotificationIndex]）。
Notification announcementAsNotification(Announcement announcement) =>
    Notification(
      id: '$announcementNotificationIdPrefix${announcement.id}',
      type: NotificationType.announcement,
      createdAt: announcement.publishedAt,
      unread: !announcement.read,
      announcement: announcement,
    );

const announcementNotificationIdPrefix = 'announcement:';

/// お知らせを差し込んだ行か（サーバーの通知ではない）。
bool isAnnouncementRow(Notification notification) =>
    notification.type == NotificationType.announcement &&
    notification.announcement != null &&
    notification.id.startsWith(announcementNotificationIdPrefix);

/// [notifications] の [from] 番目から古いほうへ見て、最初のサーバーの通知の
/// 行の位置。無ければ null。
///
/// ⚠ 既読位置（Mastodon のマーカー・Misskey の全既読）とカーソルは、サーバーの
/// 通知の id でしか通じない。お知らせの行は飛ばす。
int? firstServerNotificationIndex(
  List<Notification> notifications, [
  int from = 0,
]) {
  for (var i = from; i < notifications.length; i++) {
    if (!isAnnouncementRow(notifications[i])) return i;
  }
  return null;
}

/// 見えている行（[visibleIndexes]）のうち、一番上にあるサーバーの通知の行の
/// 位置。見えているのがお知らせの行だけなら null。
///
/// ⚠⚠ **見えていない行を既読の起点にしない**（v2.7 のリリース PR の Codex P2）。
/// お知らせの行が画面の上を占めていると、その下の一番新しい通知は画面の外に
/// あることがある。「0 行目が見えている」をその通知が見えていることと読むと、
/// お知らせを眺めただけで、まだ見ていない通知まで既読にしてしまう。
int? topVisibleServerNotificationIndex(
  List<Notification> notifications,
  Iterable<int> visibleIndexes,
) {
  int? top;
  for (final i in visibleIndexes) {
    if (i < 0 || i >= notifications.length) continue;
    if (isAnnouncementRow(notifications[i])) continue;
    if (top == null || i < top) top = i;
  }
  return top;
}

/// 通知の一覧に、範囲に入るお知らせを差し込む。
///
/// [pending] はまだ差し込んでいないお知らせ。返り値の `pending` が、次の追加
/// 読み込みまで持ち越す分。
///
/// ⚠⚠ **いま並んでいる通知より古いお知らせは、続きがあるうちは差し込まない。**
/// 末尾に並べると、まだ読み込んでいない通知より下に来て順序が崩れる。続きが
/// 無ければ（[hasMore] が false）全部差し込む。
///
/// ⚠ 通知の並び（サーバーの順）は動かさない。お知らせだけを公開日時の位置へ
/// 入れる（同じ時刻なら通知の後ろ）。
({List<Notification> merged, List<Announcement> pending}) mergeAnnouncements(
  List<Notification> notifications,
  List<Announcement> pending, {
  required bool hasMore,
}) {
  if (pending.isEmpty) return (merged: notifications, pending: const []);
  DateTime? oldest;
  for (final n in notifications) {
    if (isAnnouncementRow(n)) continue;
    if (oldest == null || n.createdAt.isBefore(oldest)) oldest = n.createdAt;
  }
  final insert = <Announcement>[];
  final keep = <Announcement>[];
  for (final a in pending) {
    final inRange =
        !hasMore || (oldest != null && !a.publishedAt.isBefore(oldest));
    (inRange ? insert : keep).add(a);
  }
  if (insert.isEmpty) return (merged: notifications, pending: keep);
  insert.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
  final merged = <Notification>[];
  var next = 0;
  for (final n in notifications) {
    while (next < insert.length &&
        insert[next].publishedAt.isAfter(n.createdAt)) {
      merged.add(announcementAsNotification(insert[next++]));
    }
    merged.add(n);
  }
  while (next < insert.length) {
    merged.add(announcementAsNotification(insert[next++]));
  }
  return (merged: merged, pending: keep);
}

/// [account] の通知の一覧に、お知らせを含めるか。
///
/// お知らせのプッシュ通知のトグルに連動する。⚠ **トグルが無いところでは常に
/// 含める**（Linux・お知らせのプッシュに対応していないサーバー）。トグルが
/// あるときは、明示的に OFF にしていなければ含める（トグルの既定は ON）。
Future<bool> includeAnnouncementsInNotifications(Account account) async {
  final hasToggle =
      AnnouncementSubscriptionService.platformSupported &&
      account.mulukhiya?.announcementPushEnabled == true;
  if (!hasToggle) return true;
  return !await AnnouncementSubscriptionService.isExplicitlyOptedOut(
    account.key.toStorageKey(),
  );
}

/// [account] の、通知の一覧に差し込むお知らせ。含めないとき・取れないときは空。
///
/// ⚠ **お知らせが取れなくても通知の一覧は止めない。**
Future<List<Announcement>> announcementsForNotifications(
  Account account, {
  required Set<NotificationType> excludeTypes,
}) async {
  if (excludeTypes.contains(NotificationType.announcement)) return const [];
  final adapter = account.adapter;
  if (adapter is! AnnouncementSupport) return const [];
  try {
    if (!await includeAnnouncementsInNotifications(account)) return const [];
    return await (adapter as AnnouncementSupport).getAnnouncements();
  } catch (_) {
    return const [];
  }
}
