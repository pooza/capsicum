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

  /// `type == 'reaction:grouped'` のとき、束ねられたリアクション (#1048)。
  ///
  /// ⚠⚠ **このとき [user] / [reaction] は来ない。**`i/notifications-grouped` の
  /// `reaction:grouped` は `note` + `reactions` だけを持つ形に差し替えられる
  /// （`notifications-grouped.ts` の grouping ループ）。**`user` を前提に
  /// 表示を組むと見出しが空になる**ので、代表は `reactions.first.user`。
  final List<MisskeyGroupedReaction>? reactions;

  /// `type == 'renote:grouped'` のとき、リノートした人たち (#1048)。
  /// こちらも [user] は来ない。
  final List<MisskeyUser>? users;

  const MisskeyNotification({
    required this.id,
    required this.type,
    required this.createdAt,
    this.user,
    this.note,
    this.reaction,
    this.achievement,
    this.reactions,
    this.users,
  });

  factory MisskeyNotification.fromJson(Map<String, dynamic> json) =>
      _$MisskeyNotificationFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyNotificationToJson(this);
}

/// `reaction:grouped` の 1 件 (#1048)。
@JsonSerializable()
class MisskeyGroupedReaction {
  final MisskeyUser user;
  final String reaction;

  const MisskeyGroupedReaction({required this.user, required this.reaction});

  factory MisskeyGroupedReaction.fromJson(Map<String, dynamic> json) =>
      _$MisskeyGroupedReactionFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyGroupedReactionToJson(this);
}
