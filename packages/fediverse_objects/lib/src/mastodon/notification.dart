import 'package:json_annotation/json_annotation.dart';

import 'account.dart';
import 'account_warning.dart';
import 'collection.dart';
import 'relationship_severance_event.dart';
import 'status.dart';

part 'notification.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonNotification {
  final String id;
  final String type;
  final DateTime createdAt;
  final MastodonAccount account;
  final MastodonStatus? status;

  /// Mastodon 4.6 Collections の `added_to_collection` / `collection_update`
  /// 通知に同梱される対象コレクション（key: `collection`）。それ以外は null (#741)。
  final MastodonCollection? collection;

  /// `severed_relationships` 通知の中身（key: `event`）。それ以外は null (#1084)。
  final MastodonRelationshipSeveranceEvent? event;

  /// `moderation_warning` 通知の中身（key: `moderation_warning`）。それ以外は
  /// null (#1084)。
  final MastodonAccountWarning? moderationWarning;

  /// サーバーが用意した代替文言 (#1042)。`supported_types[]` を送ったときだけ、
  /// **その配列に載っていない種別に対して**返る。
  final MastodonNotificationFallback? fallback;

  const MastodonNotification({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.account,
    this.status,
    this.collection,
    this.event,
    this.moderationWarning,
    this.fallback,
  });

  factory MastodonNotification.fromJson(Map<String, dynamic> json) =>
      _$MastodonNotificationFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonNotificationToJson(this);
}

/// capsicum が知らない種別に対してサーバーが用意する文言 (#1042)。
///
/// ⚠⚠ **`title` / `summary` は HTML**（`link_to` / `link_to_mention` を通る）。
///
/// ⚠ **来ない場合がある。**`NotificationFallbackConcern#fallback_title` が文言を
/// 持っているのは `severed_relationships` / `moderation_warning` /
/// `admin.sign_up` / `admin.report` / `added_to_collection` /
/// `collection_update` だけで、**それ以外では `fallback` キーは来るのに中身が
/// 両方 null** になる。さらに baseline 扱いの種別（`quote` 等）には
/// `needs_fallback?` が false を返すので `fallback` 自体が来ない。
@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonNotificationFallback {
  final String? title;
  final String? summary;

  const MastodonNotificationFallback({this.title, this.summary});

  factory MastodonNotificationFallback.fromJson(Map<String, dynamic> json) =>
      _$MastodonNotificationFallbackFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonNotificationFallbackToJson(this);
}
