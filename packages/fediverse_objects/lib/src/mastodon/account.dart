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

  /// Mastodon 4.6 のプロフィールタブ表示設定（#732）。所有者が閲覧側に対して
  /// メディア/フィーチャー/フォロー一覧の表示可否を制御する。未対応サーバーでは
  /// null（＝従来どおり全て表示）。
  final bool? showMedia;

  /// メディアタブに返信の添付を含めるか（Mastodon 4.6 `show_media_replies`、
  /// #809）。false のとき所有者はメディア返信を非表示にしたいので、メディアタブ
  /// の取得で返信を除外する。null は未対応サーバー（＝従来どおり返信も表示）。
  final bool? showMediaReplies;
  final bool? showFeatured;
  final bool? hideCollections;

  /// Mastodon 4.6 の feature_approval（コレクション掲載の承認ポリシー、#742）。
  /// `{ automatic: [...], manual: [...], current_user: ... }`。未対応では null。
  final Map<String, dynamic>? featureApproval;
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
    this.showMedia,
    this.showMediaReplies,
    this.showFeatured,
    this.hideCollections,
    this.featureApproval,
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
