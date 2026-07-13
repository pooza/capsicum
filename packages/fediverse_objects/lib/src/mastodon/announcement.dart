import 'package:json_annotation/json_annotation.dart';

part 'announcement.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonAnnouncement {
  final String id;
  final String content;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final bool allDay;
  final DateTime publishedAt;
  final DateTime? updatedAt;
  final bool read;
  final List<MastodonAnnouncementReaction> reactions;

  const MastodonAnnouncement({
    required this.id,
    required this.content,
    this.startsAt,
    this.endsAt,
    this.allDay = false,
    required this.publishedAt,
    this.updatedAt,
    this.read = false,
    this.reactions = const [],
  });

  factory MastodonAnnouncement.fromJson(Map<String, dynamic> json) =>
      _$MastodonAnnouncementFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonAnnouncementToJson(this);
}

/// お知らせに付いたリアクション 1 種 (#819)。Mastodon の
/// `Announcement::Reaction` 相当。[name] は Unicode 絵文字またはカスタム絵文字の
/// shortcode（コロン無し）。カスタム絵文字のときのみ [url] / [staticUrl] が付く。
@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonAnnouncementReaction {
  final String name;
  final int count;

  /// 自分がこのリアクションを付けているか。
  final bool me;
  final String? url;
  final String? staticUrl;

  const MastodonAnnouncementReaction({
    required this.name,
    required this.count,
    this.me = false,
    this.url,
    this.staticUrl,
  });

  factory MastodonAnnouncementReaction.fromJson(Map<String, dynamic> json) =>
      _$MastodonAnnouncementReactionFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonAnnouncementReactionToJson(this);
}
