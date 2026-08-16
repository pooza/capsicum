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

  /// `type == 'achievementEarned'` のとき解除した実績のキー（例: `notes1`, #918）。
  final String? achievement;

  const MisskeyNotification({
    required this.id,
    required this.type,
    required this.createdAt,
    this.user,
    this.note,
    this.reaction,
    this.achievement,
  });

  factory MisskeyNotification.fromJson(Map<String, dynamic> json) =>
      _$MisskeyNotificationFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyNotificationToJson(this);
}
