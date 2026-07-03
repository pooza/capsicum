class UserRelationship {
  final bool following;
  final bool followedBy;
  final bool muting;
  final bool blocking;

  /// 期限付きミュートの解除予定時刻（Mastodon 4.6 の muting_expires_at、#734）。
  /// 無期限ミュートや未対応サーバーでは null。
  final DateTime? mutingExpiresAt;

  const UserRelationship({
    this.following = false,
    this.followedBy = false,
    this.muting = false,
    this.blocking = false,
    this.mutingExpiresAt,
  });
}
