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

  /// ワードミュート（#1288）。要素は **`List<String>`（キーワードの AND）か
  /// `String`（正規表現 `/pattern/flags`）** のどちらか。
  ///
  /// ⚠⚠ **`List<List<String>>` ではない。**サーバーの型は `(string[] | string)[]`
  /// （`UserProfile.ts`）で、正規表現の行は配列に入らない素の文字列で返る。
  /// JSON スキーマ（`json-schema/user.ts`）は array of array と書いているが実体と
  /// 違う。以前は配列と決め打ちしていたので、正規表現を 1 行でも持つアカウントは
  /// `/api/i` の parse が型エラーになっていた。
  @JsonKey(fromJson: _readMuteWords)
  final List<Object>? mutedWords;
  @JsonKey(fromJson: _readMuteWords)
  final List<Object>? hardMutedWords;
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

/// `mutedWords` / `hardMutedWords` を `String | List<String>` の並びとして読む。
/// 形の合わない要素は捨てる（1 行の崩れで `/api/i` 全体を落とさない）。
List<Object>? _readMuteWords(dynamic value) {
  if (value is! List) return null;
  return [
    for (final item in value)
      if (item is String)
        item
      else if (item is List)
        [
          for (final word in item)
            if (word is String) word,
        ],
  ];
}
