import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

@JsonSerializable()
class MisskeyUser {
  final String id;
  final String username;
  final String? host;
  final String? name;
  final String? avatarUrl;
  final String? bannerUrl;
  final String? description;
  final int? followersCount;
  final int? followingCount;
  final int? notesCount;
  final bool? isBot;
  final bool? isCat;

  /// 承認制アカウント（Mastodon の `locked` 相当、#865）。プロフィール編集
  /// トグルの現在値 prefill に使う。未取得では null。
  final bool? isLocked;

  /// 発見可能・ディレクトリ掲載（Mastodon の `discoverable` 相当、#865）。
  final bool? isExplorable;
  final List<Map<String, dynamic>>? roles;
  final List<Map<String, dynamic>>? fields;
  final Map<String, String>? emojis;
  final List<List<String>>? mutedWords;
  final List<List<String>>? hardMutedWords;
  final List<Map<String, dynamic>>? pinnedNotes;
  final List<Map<String, dynamic>>? avatarDecorations;
  final List<Map<String, dynamic>>? badgeRoles;
  final List<String>? verifiedLinks;
  // ⚠⚠ **`defaultNoteVisibility` を足し直さない (#1185)。**Misskey の API には
  // **存在したことが無い** —— `packages/backend` にも `misskey-js` にも無く、
  // `git log -S` で追っても **frontend のクライアント設定 (`preferences/def.ts`)
  // にしか現れない**。サーバーが送らないので常に null で、capsicum はそれを
  // `User.defaultScope` に写していた＝**Misskey の `defaultScope` は常に null**
  // という死にコードだった。⚠ **既定の公開範囲をサーバーから読めるのは
  // Mastodon の `source.privacy` だけ**（`docs/server-settings-gap-inventory.md`
  // §5-2）。
  final DateTime? createdAt;
  final bool? canChat;
  final String? chatScope;

  /// 引っ越し先の ActivityPub URI (#1055)。引っ越していなければ null。
  ///
  /// ⚠ **URI 1 本しか来ない**（Mastodon の `moved` は Account そのもの）。
  /// `@user@host` は分からないので、画面には URL を出す。
  final String? movedTo;

  /// 凍結 / サイレンス / 削除済み (#1055)。⚠ **いずれも「通常の状態ではない」系**
  /// で、引っ越しと同じ表示ルールに束ねる。未取得では null。
  final bool? isSuspended;
  final bool? isSilenced;
  final bool? isDeleted;

  const MisskeyUser({
    required this.id,
    required this.username,
    this.host,
    this.name,
    this.avatarUrl,
    this.bannerUrl,
    this.description,
    this.followersCount,
    this.followingCount,
    this.notesCount,
    this.isBot,
    this.isCat,
    this.isLocked,
    this.isExplorable,
    this.roles,
    this.fields,
    this.emojis,
    this.mutedWords,
    this.hardMutedWords,
    this.pinnedNotes,
    this.avatarDecorations,
    this.badgeRoles,
    this.verifiedLinks,
    this.createdAt,
    this.canChat,
    this.chatScope,
    this.movedTo,
    this.isSuspended,
    this.isSilenced,
    this.isDeleted,
  });

  factory MisskeyUser.fromJson(Map<String, dynamic> json) =>
      _$MisskeyUserFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyUserToJson(this);
}
