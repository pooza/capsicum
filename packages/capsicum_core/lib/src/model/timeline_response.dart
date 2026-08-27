import 'post.dart';

/// A post that failed conversion from the server's raw format.
class SkippedPost {
  final String id;

  /// 失敗の理由。⚠ **[describeConversionFailure] を通したものだけを入れる。**
  /// この値は Sentry へ実際に送られるので、`'$e'` を入れると投稿本文が載る。
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

/// 変換に失敗した理由を、**本文を載せずに**説明する (#1027-A5)。
///
/// ⚠⚠ **`'$e'` を使わないこと。**この文字列は
/// `Sentry.captureMessage(..., params: [...])` に載り、**`logentry.params` として
/// 実際に送信される**（`hint` は `beforeSend` へ渡るだけで送られないので、
/// 現状これが唯一の観測経路）。素で埋めると:
///
/// - `FormatException.toString()` は `source`（＝変換しようとしていた生 JSON の
///   断片＝投稿本文）を含む
/// - `NoSuchMethodError.toString()` は receiver の `toString()` を含む
///
/// 逆に `TypeError` は「type 'Null' is not a subtype of type 'String'」のように
/// **型名しか出さない**ので、そのまま残すほうが原因の切り分けに効く。
///
/// ⚠ `SkippedPost.error` の doc が謳う「本文は載せない」を成立させているのは
/// **ここだけ**。呼び出し側で `'$e'` に戻すと、宣言だけが残って実態が消える。
String describeConversionFailure(Object e) {
  if (e is FormatException) return 'FormatException: ${e.message}';
  if (e is TypeError) return 'TypeError: $e';
  return e.runtimeType.toString();
}
