class UserRelationship {
  final bool following;
  final bool followedBy;
  final bool muting;
  final bool blocking;

  /// 期限付きミュートの解除予定時刻（Mastodon 4.6 の muting_expires_at、#734）。
  /// 無期限ミュートや未対応サーバーでは null。
  final DateTime? mutingExpiresAt;

  /// この相手のブースト / リノートを TL に出しているか (#1245)。
  ///
  /// Mastodon は Relationship の `showing_reblogs`、Misskey は `isRenoteMuted` の
  /// 裏返し。⚠ 既定は true（出している）。サーバーが返さないときに「出して
  /// いない」と読むと、押すと逆向きに倒れる項目になる。
  final bool showingReposts;

  const UserRelationship({
    this.following = false,
    this.followedBy = false,
    this.muting = false,
    this.blocking = false,
    this.mutingExpiresAt,
    this.showingReposts = true,
  });
}
