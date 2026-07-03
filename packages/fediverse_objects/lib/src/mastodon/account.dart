import 'package:json_annotation/json_annotation.dart';

part 'account.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonAccount {
  final String id;
  final String username;
  final String acct;
  final String displayName;
  final String note;
  final String avatar;
  final String header;

  /// Mastodon 4.6 で追加されたアバター/ヘッダー画像の alt テキスト
  /// （アクセシビリティ、#733）。未対応サーバーでは null。
  final String? avatarDescription;
  final String? headerDescription;
  final int followersCount;
  final int followingCount;
  final int statusesCount;
  final bool? bot;

  /// 標準 Mastodon API の `group` boolean。Group アクター（PieFed コミュニティ
  /// 等）を表す。`actor_type` は REST シリアライザが公開しないため、Group 判定
  /// は基本的にこの field を使う（actorType はフォーク独自経路のフォールバック）。
  final bool? group;
  final String? actorType;
  final Map<String, dynamic>? role;
  final List<Map<String, dynamic>>? roles;
  final List<Map<String, dynamic>> fields;
  final List<Map<String, dynamic>>? emojis;
  final Map<String, dynamic>? source;
  final String? url;
  final DateTime? createdAt;

  const MastodonAccount({
    required this.id,
    required this.username,
    required this.acct,
    required this.displayName,
    required this.note,
    required this.avatar,
    required this.header,
    this.avatarDescription,
    this.headerDescription,
    required this.followersCount,
    required this.followingCount,
    required this.statusesCount,
    this.bot,
    this.group,
    this.actorType,
    this.role,
    this.roles,
    this.fields = const [],
    this.emojis,
    this.source,
    this.url,
    this.createdAt,
  });

  factory MastodonAccount.fromJson(Map<String, dynamic> json) =>
      _$MastodonAccountFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonAccountToJson(this);
}
