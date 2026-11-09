import 'package:dio/dio.dart';

/// 少年ジャンプ＋の作品 URL を、アプリで開く URL へ写す (#1352)。
///
/// ⚠⚠ **「勇者アバンと獄炎の魔王」だけの決め打ち**（2026-11-10 pooza）。
///
/// - アプリが受け持つのは `https://shonenjumpplus.com/app/…` だけ（AASA・
///   Android の intent filter とも）。Web の作品 URL `/episode/<数字>` は
///   アプリに渡らない
/// - アプリの作品の ID（`ew…`）は Web の数字と別の形で、Web から組み立てられ
///   ない。`/app/episode/<Web の数字>` はアプリが「対象が存在しません」と出す
/// - ⇒ 作品ごとの対応は表で持つしかない。プリセットの利用者（デルムリン丼・
///   ダイスキー）に特に響くアバンだけを置く
///
/// ⚠ Web の話の URL は回ごとに違う数字なので、**ページを取得して作品名で
/// 見分ける**。`<title>` はそのページ自身の作品名（おすすめ欄などにほかの
/// 作品の ID が並ぶので、ID の有無では見分けない）。
///
/// 開くのは**その回ではなく作品のページ**（話の一覧・最新話が先頭）。
/// `@news@mstdn.delmulin.com` は公開前に第 1 話のリンクを「一覧から最新話を
/// 開いて」と添えて流すので、その案内と同じ動きになる。
const abanAppUrl = 'https://shonenjumpplus.com/app/episode/ew109801';

final _episodePath = RegExp(r'^/episode/\d+/?$');
final _abanTitle = RegExp(r'<title>[^<]*勇者アバンと獄炎の魔王');

/// [uri] が Web の話のページ（`https://shonenjumpplus.com/episode/<数字>`）か。
bool isJumpPlusEpisodeUrl(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.toLowerCase() == 'shonenjumpplus.com' &&
    _episodePath.hasMatch(uri.path);

/// 話のページの HTML が「勇者アバンと獄炎の魔王」のものか。
bool isAbanEpisodePage(String html) => _abanTitle.hasMatch(html);

/// 見分けた結果（URL ごと）。同じリンクを何度押しても取りに行かない。
final _cache = <String, bool>{};

final _dio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
    responseType: ResponseType.plain,
  ),
);

/// [uri] をアプリで開く URL。アバンでない・見分けられなかった（取得の失敗・
/// 時間切れ）なら null（呼ぶ側はブラウザで開く）。
///
/// [fetch] はテスト用の差し替え口。
Future<Uri?> jumpPlusAppUrlFor(
  Uri uri, {
  Future<String?> Function(Uri uri)? fetch,
}) async {
  if (!isJumpPlusEpisodeUrl(uri)) return null;
  final key = uri.toString();
  var aban = _cache[key];
  if (aban == null) {
    final String? html;
    try {
      html = await (fetch ?? _fetch)(uri);
    } catch (_) {
      return null;
    }
    if (html == null) return null;
    aban = isAbanEpisodePage(html);
    _cache[key] = aban;
  }
  return aban ? Uri.parse(abanAppUrl) : null;
}

Future<String?> _fetch(Uri uri) async {
  final response = await _dio.getUri<String>(uri);
  return response.data;
}
