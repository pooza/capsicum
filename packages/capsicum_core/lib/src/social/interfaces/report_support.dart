abstract mixin class ReportSupport {
  Future<void> reportPost(String postId, String authorId, {String? comment});

  /// 投稿を伴わない、ユーザー単位の通報 (#998)。
  ///
  /// Mastodon の `POST /api/v1/reports` は `status_ids` が任意、Misskey の
  /// `POST /api/users/report-abuse` はもともとユーザー単位なので、どちらも
  /// 投稿を特定せずに通報できる。プロフィール画面からの導線がこれを使う。
  Future<void> reportUser(String userId, {String? comment});
}
