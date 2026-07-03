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
  /// - showFeatured == false → 固定投稿（フィーチャー）セクションを隠す
  /// - hideCollections == true → フォロー/フォロワーのカウント・導線を隠す
  final bool? showMedia;
  final bool? showFeatured;
  final bool? hideCollections;

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
    this.showFeatured,
    this.hideCollections,
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
    showFeatured: showFeatured,
    hideCollections: hideCollections,
  );
}
