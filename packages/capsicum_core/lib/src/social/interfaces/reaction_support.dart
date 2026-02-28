abstract mixin class ReactionSupport {
  Future<void> addReaction(String postId, String emoji);
  Future<void> removeReaction(String postId, String emoji);
}
