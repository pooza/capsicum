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

  const MastodonNotification({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.account,
    this.status,
    this.collection,
    this.event,
    this.moderationWarning,
  });

  factory MastodonNotification.fromJson(Map<String, dynamic> json) =>
      _$MastodonNotificationFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonNotificationToJson(this);
}
