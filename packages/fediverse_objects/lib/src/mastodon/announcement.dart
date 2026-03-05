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

  const MastodonAnnouncement({
    required this.id,
    required this.content,
    this.startsAt,
    this.endsAt,
    this.allDay = false,
    required this.publishedAt,
    this.updatedAt,
    this.read = false,
  });

  factory MastodonAnnouncement.fromJson(Map<String, dynamic> json) =>
      _$MastodonAnnouncementFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonAnnouncementToJson(this);
}
