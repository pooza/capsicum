import 'post.dart';

/// A post that failed conversion from the server's raw format.
class SkippedPost {
  final String id;
  final String error;

  const SkippedPost({required this.id, required this.error});
}

/// Response from a timeline fetch, including pagination metadata.
class TimelineResponse {
  final List<Post> posts;

  /// The number of items returned by the server before any client-side
  /// filtering (e.g. skipping malformed statuses during conversion).
  final int rawCount;

  /// The ID of the last (oldest) item in the raw server response, before any
  /// client-side filtering. Used to advance the pagination cursor even when
  /// all items in a page are filtered out or fail conversion.
  final String? rawLastId;

  /// Posts that failed conversion from the server's raw format.
  final List<SkippedPost> skippedPosts;

  /// 起動時キャッシュ (#890) 用に、サーバー応答の生 JSON を [posts] と **同じ並び・
  /// 同じ件数**で持つ。変換に失敗した要素は両方から落ちるので 1:1 に保たれる。
  ///
  /// キャッシュを持たない経路（DM 等）では空。呼び出し側は空なら保存を諦めるだけで
  /// よく、生 JSON の有無で挙動が変わってはいけない。
  final List<Map<String, dynamic>> rawJson;

  const TimelineResponse({
    required this.posts,
    required this.rawCount,
    this.rawLastId,
    this.skippedPosts = const [],
    this.rawJson = const [],
  });
}
