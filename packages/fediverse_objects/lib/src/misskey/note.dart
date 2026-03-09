import 'package:json_annotation/json_annotation.dart';

import 'drive_file.dart';
import 'user.dart';

part 'note.g.dart';

@JsonSerializable()
class MisskeyNote {
  final String id;
  final DateTime createdAt;
  final String? text;
  final String userId;
  final MisskeyUser user;
  final String visibility;
  final String? renoteId;
  final MisskeyNote? renote;
  final String? replyId;
  final List<MisskeyDriveFile>? files;
  final int renoteCount;
  final int repliesCount;
  final Map<String, int>? reactions;
  final Map<String, String>? reactionEmojis;
  final String? myReaction;
  final String? cw;
  final Map<String, dynamic>? poll;

  const MisskeyNote({
    required this.id,
    required this.createdAt,
    this.text,
    required this.userId,
    required this.user,
    required this.visibility,
    this.renoteId,
    this.renote,
    this.replyId,
    this.files,
    required this.renoteCount,
    required this.repliesCount,
    this.reactions,
    this.reactionEmojis,
    this.myReaction,
    this.cw,
    this.poll,
  });

  factory MisskeyNote.fromJson(Map<String, dynamic> json) =>
      _$MisskeyNoteFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyNoteToJson(this);
}
