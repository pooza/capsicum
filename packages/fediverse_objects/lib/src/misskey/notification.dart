import 'package:json_annotation/json_annotation.dart';

import 'note.dart';
import 'user.dart';

part 'notification.g.dart';

@JsonSerializable()
class MisskeyNotification {
  final String id;
  final String type;
  final DateTime createdAt;
  final MisskeyUser? user;
  final MisskeyNote? note;
  final String? reaction;

  const MisskeyNotification({
    required this.id,
    required this.type,
    required this.createdAt,
    this.user,
    this.note,
    this.reaction,
  });

  factory MisskeyNotification.fromJson(Map<String, dynamic> json) =>
      _$MisskeyNotificationFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyNotificationToJson(this);
}
