class UserField {
  final String name;
  final String value;

  const UserField({required this.name, required this.value});
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
  final bool isGroup;
  final List<UserRole> roles;
  final List<UserField> fields;
  final Map<String, String> emojis;
  final List<AvatarDecoration> avatarDecorations;
  final String? url;

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
    this.isGroup = false,
    this.roles = const [],
    this.fields = const [],
    this.emojis = const {},
    this.avatarDecorations = const [],
    this.url,
  });
}
