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
  final String? defaultNoteVisibility;
  final DateTime? createdAt;
  final bool? canChat;
  final String? chatScope;

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
    this.defaultNoteVisibility,
    this.createdAt,
    this.canChat,
    this.chatScope,
  });

  factory MisskeyUser.fromJson(Map<String, dynamic> json) =>
      _$MisskeyUserFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyUserToJson(this);
}
