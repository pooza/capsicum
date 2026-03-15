abstract mixin class MediaUpdateSupport {
  /// Update the description (ALT text) of a media attachment.
  ///
  /// [postId] is required for backends that update media via the post
  /// editing API (e.g. Mastodon).
  Future<void> updateAttachmentDescription(
    String mediaId,
    String description, {
    required String postId,
  });
}
