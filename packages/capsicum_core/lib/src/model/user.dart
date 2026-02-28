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
  });
}
