/// プロフィールに掲載されたハッシュタグ (#1075)。Mastodon の `FeaturedTag`。
///
/// ⚠ **`endorsements`（プロフィールに他人を掲載）とは別物。**こちらは本人が
/// 自分の投稿に使うタグを掲げるもので、capsicum の主題であるタグ管理に寄っている。
class FeaturedTag {
  /// 掲載を外すとき（`DELETE /api/v1/featured_tags/:id`）に使う ID。
  final String id;

  /// `#` を含まないタグ名（表示用の大文字小文字を保つ）。
  final String name;

  /// そのタグを付けた本人の投稿数。
  final int statusesCount;

  /// そのタグを付けた最後の投稿の日付。
  final DateTime? lastStatusAt;

  const FeaturedTag({
    required this.id,
    required this.name,
    this.statusesCount = 0,
    this.lastStatusAt,
  });
}
