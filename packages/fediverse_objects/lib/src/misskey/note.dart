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
  @JsonKey(name: 'emojis')
  final Map<String, String>? noteEmojis;
  final String? myReaction;
  final String? cw;
  final Map<String, dynamic>? poll;
  final Map<String, dynamic>? channel;
  final bool? localOnly;

  /// リアクションの受付条件 (#1044)。`likeOnly` / `likeOnlyForRemote` /
  /// `nonSensitiveOnly` / `nonSensitiveOnlyForLocalLikeOnlyForRemote` / null。
  ///
  /// ⚠ **未知の値が来ても落とさないよう `String?` のまま受ける。**enum への
  /// 変換は `toCapsicum()` 側で行い、知らない値は「制限なし」として扱う
  /// （新しい受付条件が上流に増えても投稿の変換ごと落とさないため）。
  final String? reactionAcceptance;

  /// サーバーが正規化して返したハッシュタグ (#1056)。`#` は含まない。
  ///
  /// ⚠⚠ **小文字へ正規化されている**（索引のため）。表示には本文の MFM から
  /// 拾った形を使う（`capsicum_core` の `Post.tags` の注記）。
  final List<String>? tags;

  /// 指名（`specified`）ノートの宛先 (#1161)。それ以外の公開範囲では null。
  final List<String>? visibleUserIds;

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
    this.noteEmojis,
    this.myReaction,
    this.cw,
    this.poll,
    this.channel,
    this.localOnly,
    this.reactionAcceptance,
    this.visibleUserIds,
    this.tags,
  });

  factory MisskeyNote.fromJson(Map<String, dynamic> json) =>
      _$MisskeyNoteFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyNoteToJson(this);
}
