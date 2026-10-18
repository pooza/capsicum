import 'dart:async';
import 'dart:collection';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Misskey からの引用を、Mastodon で引用として見せる (#1269)。
///
/// Misskey は引用を `_misskey_quote` / `quoteUrl` で送り、承認の証明
/// （FEP-044f）を出さない。Mastodon はこれを「旧形式の引用」として `pending` の
/// まま止める。**待っても承認されない。**本文の末尾には `RE: <URL>`
/// （`quote-inline`）だけが残る。
///
/// ⚠⚠ **API は `quote` を `null` で返す**（`quote` 自体を出さない）。Mastodon の
/// `REST::StatusSerializer#quote` は `acceptable?`（承認済みか、旧形式でない）の
/// ときだけ出すため。`state: pending` が付いて届くのは、新形式の承認待ちだけ
/// （2026-10-18 に `mk.precure.fun` → 美食丼 で実測・最初の実装はここを誤り、
/// Misskey からの引用を 1 件も拾えていなかった）。
///
/// その URL を `search(resolve: true)` で引いて、引用のカードにする（2026-10-18
/// pooza 判断: 表示したときに自動で・結果は端末のメモリに持つ・同時に引く本数を
/// 絞る・扱いはリンクのプレビューと同じ）。

final _quoteInline = RegExp(
  r'(?:<br\s*/?>\s*)*<(p|span) class="quote-inline">([\s\S]*?)</\1>',
);

/// `quote-inline` の span だけを包んだ段落（Misskey の今の形）。段落ごと外さないと
/// 空の `<p></p>` が残り、本文の下に空行が出る。
final _quoteInlineParagraph = RegExp(
  r'<p>\s*<span class="quote-inline">[\s\S]*?</span>\s*</p>',
);
final _href = RegExp(r'''href=["']([^"']+)["']''');

/// 本文（HTML）の `quote-inline` の行が指す URL。無ければ null。
///
/// 形は 3 つ: Misskey が送る `<p><span class="quote-inline">RE: <a href>` /
/// `<br><br><span class="quote-inline">RE: <a href>`（本文と同じ段落）と、
/// Mastodon 自身が付ける `<p class="quote-inline">RE: <a href>`。
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
String stripQuoteFallback(String html) {
  if (_quoteInlineParagraph.hasMatch(html)) {
    return html.replaceFirst(_quoteInlineParagraph, '');
  }
  return html.replaceFirst(_quoteInline, '');
}

/// [post] が、引用元を補って見せる対象か。
///
/// 引用元が届いておらず、本文に `quote-inline` の URL があるもの。引用の状態は
/// 「無い」（旧形式の引用・上の ⚠⚠）か `pending`。⚠ 却下・取り消し・削除など、
/// サーバーが見せないと決めた状態のものは補わない。⚠ Misskey のアカウントは
/// 引用をもとから出せるので対象外（呼び出し側）。
String? quoteFallbackTarget(Post post) {
  final state = post.quoteState;
  if (state != null && state != QuoteState.pending) return null;
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
