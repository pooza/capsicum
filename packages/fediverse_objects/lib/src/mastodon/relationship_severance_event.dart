import 'package:json_annotation/json_annotation.dart';

part 'relationship_severance_event.g.dart';

/// Mastodon `REST::AccountRelationshipSeveranceEventSerializer` (#1084)。
///
/// `severed_relationships` 通知に `event` キーで同梱される。ドメインブロック・
/// アカウント停止で失われたフォロー / フォロワーの件数を持つ。
@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonRelationshipSeveranceEvent {
  final String id;

  /// `domain_block` / `user_domain_block` / `account_suspension`。
  final String type;
  final bool? purged;
  final String targetName;
  final int? followersCount;
  final int? followingCount;

  const MastodonRelationshipSeveranceEvent({
    required this.id,
    required this.type,
    required this.targetName,
    this.purged,
    this.followersCount,
    this.followingCount,
  });

  factory MastodonRelationshipSeveranceEvent.fromJson(
    Map<String, dynamic> json,
  ) => _$MastodonRelationshipSeveranceEventFromJson(json);

  Map<String, dynamic> toJson() =>
      _$MastodonRelationshipSeveranceEventToJson(this);
}
