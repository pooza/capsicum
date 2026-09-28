import 'package:json_annotation/json_annotation.dart';

import 'account.dart';
import 'account_warning.dart';
import 'collection.dart';
import 'notification.dart';
import 'relationship_severance_event.dart';
import 'status.dart';

part 'notification_group.g.dart';

/// `GET /api/v2/notifications` のレスポンス全体 (#1048)。
///
/// ⚠⚠ **v1 と形が違う。**v1 は通知 1 件ごとに `account` / `status` を丸ごと
/// 抱えていたが、v2 は**重複排除した形**（`REST::DedupNotificationGroupSerializer`）
/// で返る — アカウントと投稿はトップレベルの配列に 1 回だけ載り、各グループは
/// **ID で参照する**。同じ投稿への 20 件のリアクションで投稿が 20 回来ない代わりに、
/// クライアント側で引き当てが必要になる。
///
/// ⚠ `partial_accounts` は読まない。`expand_accounts=partial_avatars` を送った
/// ときだけ返るもので、capsicum は既定の `full` のまま使う（代表アカウントの
/// 表示名・絵文字まで必要なので、アバターだけの部分表現では足りない）。
@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonGroupedNotifications {
  final List<MastodonAccount> accounts;
  final List<MastodonStatus> statuses;
  final List<MastodonNotificationGroup> notificationGroups;

  const MastodonGroupedNotifications({
    this.accounts = const [],
    this.statuses = const [],
    this.notificationGroups = const [],
  });

  factory MastodonGroupedNotifications.fromJson(Map<String, dynamic> json) =>
      _$MastodonGroupedNotificationsFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonGroupedNotificationsToJson(this);
}

/// 束ねられた通知 1 グループ (#1048)。`REST::NotificationGroupSerializer`。
@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonNotificationGroup {
  /// 同じグループを指す鍵。束ねられない通知には
  /// `ungrouped-<notification id>` がサーバー側で振られる。
  final String groupKey;

  /// このグループに含まれる通知の総数。
  ///
  /// ⚠⚠ **`sample_account_ids` の長さではない。**代表アカウントは 8 人
  /// (`NotificationGroup::SAMPLE_ACCOUNTS_SIZE`) で打ち切られる。
  final int notificationsCount;

  final String type;

  /// グループ内で最も新しい通知の ID。
  ///
  /// ⚠⚠ **本家は数値で返す**（`NotificationGroupSerializer` がこれだけ `to_s`
  /// していない。`page_min_id` / `page_max_id` は文字列）。型定義
  /// (`api_types/notifications.ts`) は `string` だが実装と食い違っている。
  /// `as String` で読むと Mastodon の全サーバーでグループ通知が取れなくなる。
  @JsonKey(fromJson: _asString)
  final String mostRecentNotificationId;

  /// このページの範囲でグループに含まれる最も古い通知の ID。
  ///
  /// ⚠⚠ **ページングのカーソルはこれ。**`group_key` では辿れない
  /// （`max_id` / `since_id` は通知の ID を取る）。⚠ `paginated?` が false の
  /// とき（`GET /api/v2/notifications/:group_key`）は来ないので nullable。
  final String? pageMinId;
  final String? pageMaxId;

  /// グループ内で最も新しい通知の時刻。
  ///
  /// ⚠ **v2 のグループに `created_at` は無い。**時刻はこれしか無いので、
  /// 一覧の並べ替えにもこれを使う。
  final DateTime? latestPageNotificationAt;

  /// 代表アカウントの ID（新しい順・最大 8 件）。
  /// [MastodonGroupedNotifications.accounts] から引き当てる。
  final List<String> sampleAccountIds;

  /// 対象の投稿 ID（`favourite` / `reblog` / `mention` 等）。
  /// [MastodonGroupedNotifications.statuses] から引き当てる。
  final String? statusId;

  final MastodonCollection? collection;
  final MastodonRelationshipSeveranceEvent? event;
  final MastodonAccountWarning? moderationWarning;
  final MastodonNotificationFallback? fallback;

  const MastodonNotificationGroup({
    required this.groupKey,
    required this.notificationsCount,
    required this.type,
    required this.mostRecentNotificationId,
    this.pageMinId,
    this.pageMaxId,
    this.latestPageNotificationAt,
    this.sampleAccountIds = const [],
    this.statusId,
    this.collection,
    this.event,
    this.moderationWarning,
    this.fallback,
  });

  factory MastodonNotificationGroup.fromJson(Map<String, dynamic> json) =>
      _$MastodonNotificationGroupFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonNotificationGroupToJson(this);
}

String _asString(Object? value) => value.toString();
