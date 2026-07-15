import 'package:capsicum_core/capsicum_core.dart';

/// Misskey のプレビューカード（summaly `GET /url`）を URL 単位でキャッシュし、
/// 同一 URL の同時取得を 1 本に束ねる共有ストア (#772)。
///
/// Misskey の note ペイロードにはカードが含まれず、capsicum が URL ごとに
/// summaly を叩いて組み立てる。タイムラインでカードを出す（#772）とスクロール中
/// に同じ URL が何度も流れうるため、
///
/// - **メモリキャッシュ**: 一度取得した URL は結果（カード or カード無し）を保持し、
///   再取得しない。タイムラインとスレッド画面で共有する。
/// - **in-flight dedup**: 取得中の URL に対する追加要求は進行中の Future を返す。
///
/// でサーバー（モロヘイヤ経由含む）への負荷を抑える。プロセス内メモリのみで
/// 永続化はしない（セッションを跨ぐと再取得）。
class UrlPreviewCache {
  UrlPreviewCache._();
  static final UrlPreviewCache instance = UrlPreviewCache._();

  /// 取得済み結果。値が `null` は「取得したがカード化できなかった」ことを表す
  /// （再取得を避けるため negative もキャッシュする）。
  final Map<String, PreviewCard?> _cache = {};

  /// 取得中の URL → 進行中の Future（dedup 用）。
  final Map<String, Future<PreviewCard?>> _inFlight = {};

  /// 取得を試みたことがあるか（`null` 結果を含む）。
  bool has(String url) => _cache.containsKey(url);

  /// キャッシュ済みのカード。未取得・カード無しはいずれも `null`。
  PreviewCard? cached(String url) => _cache[url];

  /// URL のプレビューカードを取得する。キャッシュ済みなら即座に返し、取得中なら
  /// その Future を共有し、いずれでもなければ [fetcher] を 1 回だけ走らせて結果を
  /// キャッシュする。[fetcher]（`MisskeyAdapter.fetchUrlPreview`）は失敗時 `null`
  /// を返す前提。
  Future<PreviewCard?> fetch(
    String url,
    Future<PreviewCard?> Function() fetcher,
  ) {
    if (_cache.containsKey(url)) return Future.value(_cache[url]);
    final existing = _inFlight[url];
    if (existing != null) return existing;
    // fetcher は失敗時 null を返す契約だが、将来別 fetcher が throw しても
    // in-flight エントリが残って以後その URL の取得が恒久的に詰まらないよう、
    // 成否に関わらず whenComplete で必ず解除する。
    final future = fetcher()
        .then<PreviewCard?>((card) {
          _cache[url] = card;
          return card;
        })
        .catchError((Object _) {
          _cache[url] = null;
          return null;
        })
        .whenComplete(() => _inFlight.remove(url));
    _inFlight[url] = future;
    return future;
  }
}
