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

  /// `type == 'roleAssigned'` のとき付与されたロール（`Role` の lite 形・#1187）。
  /// ⚠ **型付きにしない。**`id` / `name` / `color` / `iconUrl` しか使わず、
  /// 残り（`description` / `isPublic` / `displayOrder` 等）は capsicum に用途が
  /// 無い。読む側（`extensions.dart`）が `UserRole` へ写す。
  final Map<String, dynamic>? role;

  /// `type == 'exportCompleted'` のとき書き出した対象 (#1187)。
  /// `antenna` / `blocking` / `clip` / `favorite` / `following` / `muting`
  /// / `note` / `userList` のいずれか。
  final String? exportedEntity;

  /// `type == 'exportCompleted'` のとき書き出したファイルの drive ID (#1187)。
  final String? fileId;

  /// `type == 'scheduledNotePostFailed'` のとき失敗した予約投稿 (#1187)。
  ///
  /// ⚠ **`NoteDraft` そのもの。**`scheduledAt` は **epoch ミリ秒の int** で来る
  /// （`notes/drafts/list` と同じ形）ので、読む側が変換する。
  final Map<String, dynamic>? noteDraft;

  /// `type == 'chatRoomInvitationReceived'` のとき招待 (#1187)。
  /// `ChatRoomInvitation` の packed 形で、`misskeyChatRoomInvitationFromMap`
  /// がそのまま食える。
  final Map<String, dynamic>? invitation;

  /// `type == 'followRequestAccepted'` のとき承認者が添えた一言 (#1187)。
  final String? message;

  /// `type == 'app'` の本文 (#1187)。⚠ **これが通知の中身そのもの。**
  final String? body;

  /// `type == 'app'` の見出し (#1187)。アプリ名が入ることが多い。
  final String? header;

  /// `type == 'app'` のアイコン URL (#1187)。
  ///
  /// ⚠ **capsicum は使っていない。**通知の行頭は種別アイコンで揃えてあり、
  /// `app` だけ別の絵を出すと並びが崩れる。**読んでいることを残すために持つ。**
  final String? icon;

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
    this.role,
    this.exportedEntity,
    this.fileId,
    this.noteDraft,
    this.invitation,
    this.message,
    this.body,
    this.header,
    this.icon,
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
