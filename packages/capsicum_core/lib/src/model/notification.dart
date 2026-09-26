import 'announcement.dart';
import 'collection.dart';
import 'post.dart';
import 'user.dart';

enum NotificationType {
  mention,
  reblog,
  favourite,
  follow,
  followRequest,
  reaction,
  poll,
  update,
  login,
  createToken,
  chat,
  announcement,
  // Misskey の実績解除通知 (achievementEarned, #918)。Mastodon 等価なし。
  // 解除した実績のキーは [Notification.achievement] に載る。
  achievementEarned,
  // Mastodon 4.6 Collections (FEP-7aa9) の被フィーチャー通知 (#741)。Misskey 等価なし。
  addedToCollection,
  collectionUpdate,
  // Mastodon: ドメインブロック・アカウント停止で関係が失われた (#1084)。
  // 中身は [Notification.severance]。Misskey 等価なし。
  severedRelationships,
  // Mastodon: 管理者からのモデレーション警告 (#1084)。中身は
  // [Notification.moderationWarning]。Misskey 等価なし。
  moderationWarning,
  other,
}

/// 関係が失われた事由 (#1084)。Mastodon の `RelationshipSeveranceEvent#type`。
enum RelationshipSeveranceKind {
  /// 自サーバーの管理者が相手のドメインをブロックした。
  domainBlock,

  /// 自分が相手のドメインをブロックした。
  userDomainBlock,

  /// 自サーバーの管理者が相手のアカウントを停止した。
  accountSuspension,

  /// 未知の事由（上流で種類が増えた場合）。
  unknown,
}

/// `severedRelationships` 通知の中身 (#1084)。
class RelationshipSeverance {
  final RelationshipSeveranceKind kind;

  /// ブロックされたドメイン、または停止されたアカウント（`user@host`）。
  final String targetName;
  final int followersCount;
  final int followingCount;

  const RelationshipSeverance({
    required this.kind,
    required this.targetName,
    this.followersCount = 0,
    this.followingCount = 0,
  });
}

/// 管理者が取った措置 (#1084)。Mastodon の `AccountWarning#action`。
enum ModerationWarningAction {
  none,
  disable,
  markStatusesAsSensitive,
  deleteStatuses,
  sensitive,
  silence,
  suspend,

  /// 未知の措置（上流で種類が増えた場合）。
  unknown,
}

/// `moderationWarning` 通知の中身 (#1084)。
class ModerationWarning {
  /// 異議申し立てページ（`/disputes/strikes/:id`）を開くための ID。
  final String id;
  final ModerationWarningAction action;

  /// 管理者が添えた説明文（任意）。
  final String? text;

  const ModerationWarning({required this.id, required this.action, this.text});
}

class Notification {
  final String id;
  final NotificationType type;
  final DateTime createdAt;
  final User? user;
  final Post? post;
  final String? reaction;
  final bool unread;

  /// `type == NotificationType.announcement` のときのお知らせ本体 (#569)。
  /// お知らせは [user] / [post] を持たず本文を [Announcement.content] に
  /// 抱えるため、デスクトップ通知ディスパッチャ等が本文を取り出せるよう
  /// 別途保持する。それ以外の type では null。
  final Announcement? announcement;

  /// `type == addedToCollection / collectionUpdate` のとき同梱される対象
  /// コレクション (#741)。どのコレクションに載せられた／更新されたかを通知行に
  /// 表示するために保持する。それ以外の type では null。
  final Collection? collection;

  /// `type == achievementEarned` のとき解除した実績のキー (#918)。
  /// Misskey の `achievement` フィールド（例: `notes1`）をそのまま持ち、
  /// 表示側が `achievementCatalog` で実績名に解決する。それ以外の type では null。
  final String? achievement;

  /// `type == severedRelationships` のときの中身 (#1084)。それ以外は null。
  final RelationshipSeverance? severance;

  /// `type == moderationWarning` のときの中身 (#1084)。それ以外は null。
  final ModerationWarning? moderationWarning;

  const Notification({
    required this.id,
    required this.type,
    required this.createdAt,
    this.user,
    this.post,
    this.reaction,
    this.unread = true,
    this.announcement,
    this.collection,
    this.achievement,
    this.severance,
    this.moderationWarning,
  });
}
