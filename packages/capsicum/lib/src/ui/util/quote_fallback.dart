import 'dart:async';
import 'dart:collection';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Misskey からの引用を、Mastodon で引用として見せる (#1269)。
///
/// Misskey は引用を `_misskey_quote` / `quoteUrl` で送り、承認の証明
/// （FEP-044f）を出さない。Mastodon はこれを「旧形式の引用」として `pending` の
/// まま止め、`quoted_status` を返さない。**待っても承認されない。**本文の末尾には
/// `RE: <URL>`（`quote-inline`）だけが残る。
///
/// その URL を `search(resolve: true)` で引いて、引用のカードにする（2026-10-18
/// pooza 判断: 表示したときに自動で・結果は端末のメモリに持つ・同時に引く本数を
/// 絞る・扱いはリンクのプレビューと同じ）。

final _quoteInline = RegExp(
  r'(?:<br\s*/?>\s*)*<(p|span) class="quote-inline">([\s\S]*?)</\1>',
);
final _href = RegExp(r'''href=["']([^"']+)["']''');

/// 本文（HTML）の `quote-inline` の行が指す URL。無ければ null。
///
/// 形は 2 つ: Misskey が送る `<br><br><span class="quote-inline">RE: <a href>`
/// と、Mastodon 自身が付ける `<p class="quote-inline">RE: <a href>`。
String? quoteFallbackUrl(String? html) {
  if (html == null) return null;
  final inline = _quoteInline.firstMatch(html);
  if (inline == null) return null;
  final href = _href.firstMatch(inline.group(2)!)?.group(1);
  if (href == null) return null;
  return href.replaceAll('&amp;', '&');
}

/// 本文から `quote-inline` の行（と、その前の改行）を外す。引用のカードを出す
/// ときだけ使う（Mastodon の Web と同じ扱い）。
String stripQuoteFallback(String html) => html.replaceFirst(_quoteInline, '');

/// [post] が、引用元を補って見せる対象か。
///
/// 引用の状態が `pending` で、引用元が届いておらず、本文に `quote-inline` の URL が
/// あるもの。⚠ Misskey のアカウントは引用をもとから出せるので対象外（呼び出し側）。
String? quoteFallbackTarget(Post post) {
  if (post.quoteState != QuoteState.pending) return null;
  if (post.quote != null || !post.isHtml) return null;
  return quoteFallbackUrl(post.content);
}

/// 引用元の URL を投稿に解決する。結果を端末のメモリに持ち、同時に引く本数を
/// 絞る (#1269)。
///
/// ⚠ **キーにアカウントを含める。**解決した投稿の id はそのアカウントのサーバーの
/// もので、見える範囲もアカウントで違う。
/// ⚠ 「見つからない」（null）は持つ（同じ URL を何度も引かない）。通信の失敗は
/// 持たない（次に表示したときに引き直す）。
class QuoteFallbackResolver {
  QuoteFallbackResolver({this.limit = 300, this.concurrency = 2});

  static final instance = QuoteFallbackResolver();

  final int limit;
  final int concurrency;

  final _cache = <String, Future<Post?>>{};
  final _waiting = Queue<Completer<void>>();
  int _running = 0;

  Future<Post?> resolve(String accountKey, SearchSupport search, String url) {
    final key = '$accountKey|$url';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit; // 新しい側へ
      return hit;
    }
    final future = _throttled(() => _lookup(search, url)).catchError((
      Object error,
    ) {
      _cache.remove(key);
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'quote.fallback',
          level: SentryLevel.info,
          message: error.runtimeType.toString(),
        ),
      );
      return null;
    });
    _cache[key] = future;
    if (_cache.length > limit) _cache.remove(_cache.keys.first);
    return future;
  }

  static Future<Post?> _lookup(SearchSupport search, String url) async {
    final results = await search.search(url);
    return results.posts.where((p) => p.url == url).firstOrNull ??
        results.posts.firstOrNull;
  }

  Future<T> _throttled<T>(Future<T> Function() task) async {
    if (_running >= concurrency) {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}
