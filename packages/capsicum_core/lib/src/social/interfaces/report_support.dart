abstract mixin class ReportSupport {
  Future<void> reportPost(String postId, String authorId, {String? comment});
}
