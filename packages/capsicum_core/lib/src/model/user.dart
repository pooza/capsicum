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

  const User({
    required this.id,
    required this.username,
    this.displayName,
    this.host,
    this.avatarUrl,
    this.bannerUrl,
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
  });

  User copyWithIsCat(bool isCat) => User(
    id: id,
    username: username,
    displayName: displayName,
    host: host,
    avatarUrl: avatarUrl,
    bannerUrl: bannerUrl,
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
  );
}
