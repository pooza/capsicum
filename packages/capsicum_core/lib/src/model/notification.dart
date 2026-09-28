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
  // 購読中のユーザーが投稿した (#1177)。Mastodon の `status` / Misskey の `note`。
  // ⚠ ベル購読した相手の新規投稿で、メンションではない。
  newPost,
  // 引用された (#1177)。Mastodon / Misskey とも `quote`。
  //
  // ⚠⚠ **[mention] に寄せない。**寄せると**種別フィルタで切り分けられなくなる**
  // （表が送信名の正本でもあるため・#1042）。⚠ ネイティブ側の
  // `NotificationTypeLabel.swift` は #248 以来これを「メンション」と出していたので、
  // **プッシュの見出しが「引用」に変わる。**
  quote,
  // 引用元の投稿が編集された (#1177)。Mastodon の `quoted_update`。Misskey 等価なし。
  quotedUpdate,
  // Mastodon の年間まとめ (#Wrapstodon・#1177)。⚠ **投稿が付かないので、
  // 見出しが無いと何の通知か読めない。**
  annualReport,
  // 管理者向け: 新規登録があった / 通報があった (#1177)。
  // ⚠ 管理者だけが受け取る。Misskey 等価なし。
  adminSignUp,
  adminReport,
  // Misskey: 予約投稿が投稿された / 失敗した (#1177)。
  //
  // ⚠⚠ **[scheduledPostFailed] がこの Issue でいちばん実害がある。**capsicum
  // 自身が予約投稿を作れるのに、**失敗したことが「通知」としか出ない** ＝
  // 「投稿したつもりが出ていない」に気づけない。
  scheduledPostPosted,
  scheduledPostFailed,
  // Misskey: 送ったフォローリクエストが承認された (#1177)。
  // ⚠ 投稿が付かないので、見出しが無いと読めない。
  followRequestAccepted,
  // Misskey: ロールが付与された (#1177)。⚠ 同上。
  roleAssigned,
  // Misskey: チャットルームに招待された (#1177)。
  //
  // ⚠⚠ **[chat] に寄せない。**あれはプッシュ専用の `newChatMessage`
  // （#248 / #765）＝「メッセージが来た」で、**招待とは別物**。寄せると見出しが嘘になる。
  chatInvitation,
  // Misskey: エクスポートが完了した (#1177)。⚠ 投稿が付かないので読めない。
  exportCompleted,
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

  /// 束ねられた通知の同一グループを指す鍵 (#1048)。グループ化して取得していない
  /// ときは null。
  ///
  /// ⚠ **表示には使わない。**`id` と同じくサーバーの文字列で、同じグループを
  /// 再取得したときに突き合わせるためだけに持つ。
  final String? groupKey;

  /// このグループに含まれる通知の件数 (#1048)。束ねていないときは 1。
  ///
  /// ⚠⚠ **[sampleUsers] の長さと一致しない。**サーバーが返す代表アカウントは
  /// 上限つき（Mastodon は 8 人）なので、「20 人がお気に入りしました」を出すには
  /// こちらを読む。**`sampleUsers.length` で件数を出すと 8 で止まる。**
  ///
  /// ⚠ Misskey は 1 ページ内の連続した通知しか束ねないので、この件数も
  /// 「そのページで見えたぶん」に留まる（Mastodon は履歴全体を数える）。
  final int groupCount;

  /// グループの代表アカウント（新しい順・#1048）。束ねていないときは空。
  ///
  /// ⚠ **[user] は先頭と同じ**（最も新しい 1 人）。既存の表示を壊さないために
  /// [user] は常に埋める。
  final List<User> sampleUsers;

  /// サーバーが用意した代替の見出し (#1042)。capsicum が名前を知らない種別の
  /// ときだけ載る。
  ///
  /// ⚠⚠ **HTML。**Mastodon の `fallback.title` は `link_to_mention` 等を通るので
  /// `<a>` を含む。素の [Text] に入れるとタグが見えるので、HTML として描く。
  ///
  /// ⚠ **Mastodon が文言を用意しているのは非 baseline の種別だけ。**本当に
  /// 新しい種別では `title` も `summary` も null で来る（`fallback` キー自体は
  /// 来る）。**「supported_types を送れば未知の型が必ず読めるようになる」わけでは
  /// ない**ので、[NotificationType.other] の既定表示は残すこと。
  final String? fallbackTitle;

  /// [fallbackTitle] に続く説明 (#1042)。こちらも HTML。
  final String? fallbackBody;

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
    this.groupKey,
    this.groupCount = 1,
    this.sampleUsers = const [],
    this.fallbackTitle,
    this.fallbackBody,
  });
}
