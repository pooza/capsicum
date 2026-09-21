import 'collection.dart';
import 'post_scope.dart';

class UserField {
  final String name;
  final String value;
  final DateTime? verifiedAt;

  const UserField({required this.name, required this.value, this.verifiedAt});
}

class UserRole {
  final String id;
  final String name;
  final String? color;
  final String? iconUrl;
  final bool isAdmin;

  const UserRole({
    required this.id,
    required this.name,
    this.color,
    this.iconUrl,
    this.isAdmin = false,
  });
}

class AvatarDecoration {
  final String id;
  final String url;
  final double angle;
  final bool flipH;
  final double offsetX;
  final double offsetY;

  const AvatarDecoration({
    required this.id,
    required this.url,
    this.angle = 0,
    this.flipH = false,
    this.offsetX = 0,
    this.offsetY = 0,
  });
}

/// 引っ越し先のアカウント (#1055)。
///
/// ⚠ **サーバーによって分かる粒度が違う。**Mastodon の `moved` は Account
/// オブジェクトそのものなので [userId] / [handle] まで分かるが、Misskey の
/// `movedTo` は **ActivityPub の URI 1 本**しか来ない。したがって画面は
/// 「[handle] があれば handle、無ければ [url]」で出し、遷移は常に [url] を
/// `openFediverseLink` へ渡す形にする（どちらの粒度でも同じ導線になる）。
class MovedTo {
  /// 引っ越し先の URL。Mastodon は `moved.url`。
  ///
  /// ⚠⚠ **Misskey では null。**あちらの `movedTo` は URI ではなく[userId]
  /// （下記）。null のときは**リンクにしない** —— 開けない文字列をタップ可能に
  /// 見せない。
  final String? url;

  /// `@user@host`。Mastodon のみ分かる。Misskey は null。
  final String? handle;

  /// 引っ越し先のアカウント ID（このサーバーから見た ID）。
  ///
  /// ⚠⚠ **Misskey の `movedTo` はこれ。**json-schema は `format: 'uri'` と
  /// 書いているが実装と合っておらず、`UserEntityService` は
  /// `resolvePerson(movedToUri).then(user => user.id)` ＝**ローカル DB の aid**
  /// を返す（本家フロントも `MkAccountMoved.vue` で `users/show({ userId })`
  /// として扱っている）。⚠ **これを [url] に入れると生の ID が画面に出て、
  /// タップしても開けない。**
  ///
  /// 行き先はプロフィール画面が `users/show` で解決して出す（#1144・
  /// `profile_screen.dart` の `_resolveMovedTo`）。
  final String? userId;

  const MovedTo({this.url, this.handle, this.userId});
}

class User {
  final String id;
  final String username;
  final String? displayName;
  final String? host;
  final String? avatarUrl;
  final String? bannerUrl;

  /// アバター/ヘッダー画像の alt テキスト（Mastodon 4.6 の
  /// avatar_description / header_description、#733）。未対応サーバーでは null。
  final String? avatarDescription;
  final String? bannerDescription;
  final String? description;
  final int followersCount;
  final int followingCount;
  final int postCount;
  final bool isBot;
  final bool isCat;
  final bool isGroup;
  final List<UserRole> roles;
  final List<UserField> fields;
  final Map<String, String> emojis;
  final List<AvatarDecoration> avatarDecorations;
  final String? url;
  final DateTime? createdAt;
  final PostScope? defaultScope;

  /// Misskey 用。サーバー側のロール policy から導出される
  /// 「このユーザーが chat を利用可能か」フラグ。Mastodon 等
  /// chat 概念のないサーバーでは null。
  final bool? canChat;

  /// Mastodon 4.6 のプロフィールタブ表示設定（#732）。所有者が閲覧側に対して
  /// 表示を制御する。null は未対応サーバー（＝従来どおり全て表示）。
  /// - showMedia == false → メディアタブを隠す
  /// - showMediaReplies == false → メディアタブに返信の添付を含めない（#809）
  /// - showFeatured == false → 固定投稿（フィーチャー）セクションを隠す
  /// - hideCollections == true → フォロー/フォロワーのカウント・導線を隠す
  final bool? showMedia;
  final bool? showMediaReplies;
  final bool? showFeatured;
  final bool? hideCollections;

  /// このアカウントをコレクションに載せる際の承認ポリシー
  /// （Mastodon 4.6 の feature_approval、#742）。未対応サーバーでは null。
  final FeatureApproval? featureApproval;

  /// 承認制アカウント（フォローを手動承認）。Mastodon `locked` / Misskey
  /// `isLocked`（#865）。プロフィール編集トグルの現在値 prefill に使う。
  /// 未取得・未対応では null。
  final bool? locked;

  /// ディレクトリ掲載・発見可能。Mastodon `discoverable` / Misskey
  /// `isExplorable`（#865）。未取得・未対応では null。
  final bool? discoverable;

  /// 引っ越し先 (#1055)。引っ越していなければ null。
  ///
  /// ⚠ **読む側だけの情報。**引っ越しを「する」側（`i/move` /
  /// `accounts/:id/move`）はアカウントの生死に関わるのでクライアントに持たせない
  /// （棚卸しの分類 C）。
  final MovedTo? movedTo;

  /// 凍結されている (#1055)。Mastodon の `suspended` / Misskey の `isSuspended`。
  ///
  /// ⚠⚠ **「Mastodon には相当フィールドが無い」は誤りだった**（v1.65 のリリース
  /// 前レビューで訂正）。`account_serializer.rb` の
  /// `attribute :suspended, if: :unavailable?` が通常の `/api/v1/accounts/:id`
  /// で返る。⚠ **Mastodon 側では削除済みもここに畳まれる**（`unavailable? =
  /// deleted? || suspended?`）。
  final bool suspended;

  /// サイレンス（制限）されている (#1055)。Mastodon の `limited` /
  /// Misskey の `isSilenced`。
  ///
  /// ⚠ **Mastodon の JSON キーは `silenced` ではなく `limited`**（serializer が
  /// 改名している）。
  ///
  /// ⚠⚠ **Misskey ではモデレーションのサイレンスではない (#1144)。**
  /// `getUserPolicies(...).canPublicNote` の否定なので、新規アカウントの制限
  /// ロール等でも true になる。逆に**リモートユーザーにはロールが付かない**ので、
  /// インスタンス単位のサイレンス配下でも false。表示は「公開範囲が制限されて
  /// います」に留め、「サイレンス」と言い切らない。
  final bool silenced;

  /// 削除済み (#1055)。Misskey の `isDeleted`。
  ///
  /// ⚠ **Mastodon では常に false** —— あちらは [suspended] に畳まれるため。
  ///
  /// ⚠⚠ **Misskey でも他人については常に false (#1144)。**`UserEntityService` が
  /// `isDetailed && isMe` のブロックの中でしか返さないので、他人の `users/show`
  /// には含まれない。削除済みのアカウントは自分のプロフィールも見られないので、
  /// **表示には使わない**（バッジは外した）。
  final bool deleted;

  const User({
    required this.id,
    required this.username,
    this.displayName,
    this.host,
    this.avatarUrl,
    this.bannerUrl,
    this.avatarDescription,
    this.bannerDescription,
    this.description,
    this.followersCount = 0,
    this.followingCount = 0,
    this.postCount = 0,
    this.isBot = false,
    this.isCat = false,
    this.isGroup = false,
    this.roles = const [],
    this.fields = const [],
    this.emojis = const {},
    this.avatarDecorations = const [],
    this.url,
    this.createdAt,
    this.defaultScope,
    this.canChat,
    this.showMedia,
    this.showMediaReplies,
    this.showFeatured,
    this.hideCollections,
    this.featureApproval,
    this.locked,
    this.discoverable,
    this.movedTo,
    this.suspended = false,
    this.silenced = false,
    this.deleted = false,
  });

  User copyWithIsCat(bool isCat) => User(
    id: id,
    username: username,
    displayName: displayName,
    host: host,
    avatarUrl: avatarUrl,
    bannerUrl: bannerUrl,
    avatarDescription: avatarDescription,
    bannerDescription: bannerDescription,
    description: description,
    followersCount: followersCount,
    followingCount: followingCount,
    postCount: postCount,
    isBot: isBot,
    isCat: isCat,
    isGroup: isGroup,
    roles: roles,
    fields: fields,
    emojis: emojis,
    avatarDecorations: avatarDecorations,
    url: url,
    createdAt: createdAt,
    defaultScope: defaultScope,
    canChat: canChat,
    showMedia: showMedia,
    showMediaReplies: showMediaReplies,
    showFeatured: showFeatured,
    hideCollections: hideCollections,
    featureApproval: featureApproval,
    locked: locked,
    discoverable: discoverable,
    movedTo: movedTo,
    suspended: suspended,
    silenced: silenced,
    deleted: deleted,
  );
}
