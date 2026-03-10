class UserRelationship {
  final bool following;
  final bool followedBy;
  final bool muting;
  final bool blocking;

  const UserRelationship({
    this.following = false,
    this.followedBy = false,
    this.muting = false,
    this.blocking = false,
  });
}
