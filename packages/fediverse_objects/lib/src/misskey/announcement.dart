import 'package:json_annotation/json_annotation.dart';

part 'announcement.g.dart';

@JsonSerializable()
class MisskeyAnnouncement {
  final String id;
  final String title;
  final String text;
  final String? imageUrl;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isRead;

  const MisskeyAnnouncement({
    required this.id,
    required this.title,
    required this.text,
    this.imageUrl,
    required this.createdAt,
    this.updatedAt,
    this.isRead = false,
  });

  factory MisskeyAnnouncement.fromJson(Map<String, dynamic> json) =>
      _$MisskeyAnnouncementFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyAnnouncementToJson(this);
}
