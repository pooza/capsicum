import '../../model/post.dart';

/// モロヘイヤがサーバー側で「削除＋再投稿」した結果を取り込む (#909)。
///
/// 「削除してタグづけ」(`POST /mulukhiya/api/status/tags`) は、capsicum が投稿
/// するのではなく**モロヘイヤが削除と再投稿を代行する**。そのため capsicum は
/// 新しい投稿の id を知らず、「削除して再編集」のように楽観挿入 (#717) できない。
/// 結果、ライブ更新 OFF やスクロール中は再投稿が streaming 待ちになる (#887 の残り)。
///
/// モロヘイヤは**SNS 本体の投稿 API のレスポンスをそのまま**返す（モロヘイヤ独自
/// のラップは無い）。形は SNS で違い、Mastodon はトップレベルがそのまま status、
/// Misskey は `{"createdNote": {...}}`。**どちらの形が来るかを知っているのは
/// アダプター**なので、変換をここに置く。
/// 仕様の正本は pooza/mulukhiya-toot-proxy#4491（ステージング実測）と `docs/api.md`。
abstract mixin class MulukhiyaRepostSupport {
  /// 再投稿レスポンスの生 JSON を [Post] に変換する。
  ///
  /// 想定外の形（モロヘイヤやサーバーの版差）では **null を返して呼び出し側を
  /// 素通しさせる**こと。ここで投げると、サーバー側では成功している再投稿が
  /// クライアントの都合で失敗扱いになる。
  Post? parseRepostedPost(Map<String, dynamic> json);
}
