import '../../model/post.dart';

/// 前回のタイムラインをディスクに残し、次の起動で即描画するための復号側 (#890)。
///
/// 保存するのは **サーバー応答の生 JSON**（[TimelineResponse.rawJson]）で、読み
/// 出しはこの mixin を持つアダプタが自分のモデル経由で [Post] に戻す。ドメイン
/// モデル側に codec を持たせると `Post` / `User` / `Attachment` / `Poll` …
/// 一式の直列化をモデル変更のたびに追従する必要が出るため、既存の `fromJson`
/// をそのまま使える生 JSON 方式を採る。
abstract mixin class TimelineCacheSupport {
  /// キャッシュした生 JSON を投稿へ戻す。壊れた要素は黙って捨ててよい
  /// （キャッシュは表示の先出しでしかなく、直後に REST の結果で置き換わる）。
  List<Post> decodeCachedPosts(List<Map<String, dynamic>> raw);
}
