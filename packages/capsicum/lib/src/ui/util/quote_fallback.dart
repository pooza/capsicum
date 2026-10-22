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

/// ⚠⚠ **手前の `<br>` を正規表現に含めない**（#1304）。以前は先頭に
/// `(?:<br\s*/?>\s*)*` を付けていたので、`<br>` が大量に並んだ本文では、
/// 各位置から `<br>` の列を食べ直しては外れる**二乗の手間**になっていた（表示の
/// たびに UI スレッドで走る）。手前の `<br>` は [_brTag] で後ろ向きにたどる。
final _quoteInline = RegExp(r'<(p|span) class="quote-inline">([\s\S]*?)</\1>');
final _brTag = RegExp(r'^<br\s*/?>$');

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
///
/// ⚠ **http(s) の URL だけを返す**（v2.4 リリース前レビュー）。Mastodon の検索は
/// http(s) 以外を URL として扱わず全文検索へ回すので、`RE: <a href="xmpp:…">` の
/// ような本文から、無関係な投稿を引用元として出せてしまう。
String? quoteFallbackUrl(String? html) {
  if (html == null) return null;
  final inline = _quoteInline.firstMatch(html);
  if (inline == null) return null;
  final href = _href.firstMatch(inline.group(2)!)?.group(1);
  if (href == null) return null;
  final url = href.replaceAll('&amp;', '&');
  final scheme = Uri.tryParse(url)?.scheme;
  if (scheme != 'https' && scheme != 'http') return null;
  return url;
}

/// 本文から `quote-inline` の行（と、その前の改行）を外す。引用のカードを出す
/// ときだけ使う（Mastodon の Web と同じ扱い）。
String stripQuoteFallback(String html) {
  if (_quoteInlineParagraph.hasMatch(html)) {
    return html.replaceFirst(_quoteInlineParagraph, '');
  }
  final inline = _quoteInline.firstMatch(html);
  if (inline == null) return html;
  final start = _startOfLeadingBreaks(html, inline.start);
  return html.replaceRange(start, inline.end, '');
}

/// [end] の手前に続く `<br>`（と、その後ろの空白）の先頭の位置。無ければ [end]。
///
/// ⚠ 後ろ向きに 1 回だけたどる（線形）。正規表現で書くと二乗になる（[_quoteInline]）。
/// 空白を外すのは `<br>` の後ろにあるものだけ（以前の `(?:<br\s*/?>\s*)*` と同じ）。
int _startOfLeadingBreaks(String html, int end) {
  var start = end;
  while (true) {
    var t = start;
    while (t > 0 && _isSpace(html.codeUnitAt(t - 1))) {
      t--;
    }
    if (t == 0 || html.codeUnitAt(t - 1) != 0x3E /* > */ ) return start;
    final lt = html.lastIndexOf('<', t - 1);
    if (lt < 0 || !_brTag.hasMatch(html.substring(lt, t))) return start;
    start = lt;
  }
}

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

/// [post] が、引用元を補って見せる対象か。
///
/// 引用元が届いておらず、本文に `quote-inline` の URL があり、引用の状態が
/// 「無い」（旧形式の引用・上の ⚠⚠）もの。⚠ Misskey のアカウントは引用を
/// もとから出せるので対象外（呼び出し側）。
///
/// ⚠⚠ **`pending` は補わない**（v2.4 リリース前レビュー・2026-10-18 pooza 判断）。
/// 新形式の承認待ちで、引用された人がまだ承認していない。補うと同意の仕組み
/// （FEP-044f）をクライアントで迂回することになり、Mastodon の Web とも違って
/// 見える。却下・取り消し・削除なども同じく補わない。
/// ⚠ ただし旧形式の引用は、引用された人が外しても（revoked / rejected）
/// Mastodon が状態を返さない（`quote` ごと null）ので、補い続ける。上流の制約。
String? quoteFallbackTarget(Post post) {
  if (post.quoteState != null) return null;
  if (post.quote != null || !post.isHtml) return null;
  return quoteFallbackUrl(post.content);
}

/// 引用元の URL を投稿に解決する。結果を端末のメモリに持ち、同時に引く本数を
/// 絞る (#1269)。
///
/// ⚠ **キーにアカウントを含める。**解決した投稿の id はそのアカウントのサーバーの
/// もので、見える範囲もアカウントで違う。
/// ⚠ 「見つからない」（null）は持つ（同じ URL を何度も引かない）。通信の失敗は
/// [failureTtl] の間だけ持つ (#1304)。持たないと、429 / 5xx が続く間スクロールの
/// たびに同じ URL を引き直す。過ぎたら次に表示したときに引き直す。
///
/// ⚠ **画面から外れたタイルのぶんは引かない** (#1304)。タイルは [resolve] で
/// 関心を上げ、外れたら [release] で下ろす。待ち行列に居る間に関心が 0 になった
/// ものは、順番が来ても引かない（以前は流れたタイルのぶんも順番どおり引いていた）。
class QuoteFallbackResolver {
  QuoteFallbackResolver({
    this.limit = 300,
    this.concurrency = 2,
    this.failureTtl = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  static final instance = QuoteFallbackResolver();

  final int limit;
  final int concurrency;
  final Duration failureTtl;
  final DateTime Function() _now;

  final _cache = <String, Future<Post?>>{};
  final _failedUntil = <String, DateTime>{};
  final _interest = <String, int>{};
  final _waiting = Queue<Completer<void>>();
  int _running = 0;

  static String _keyOf(String accountKey, String url) => '$accountKey|$url';

  Future<Post?> resolve(String accountKey, SearchSupport search, String url) {
    final key = _keyOf(accountKey, url);
    _interest[key] = (_interest[key] ?? 0) + 1;
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit; // 新しい側へ
      return hit;
    }
    final failedUntil = _failedUntil[key];
    if (failedUntil != null) {
      if (_now().isBefore(failedUntil)) return Future.value(null);
      _failedUntil.remove(key);
    }
    final future = _throttled(key, () => _lookup(search, url)).catchError((
      Object error,
    ) {
      _cache.remove(key);
      // 取り消し（画面から外れた）は失敗ではない。次に表示したら引く。
      if (error is _Cancelled) return null;
      _failedUntil[key] = _now().add(failureTtl);
      if (_failedUntil.length > limit) {
        _failedUntil.remove(_failedUntil.keys.first);
      }
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

  /// [resolve] で上げた関心を下ろす（タイルが画面から外れた・別の投稿になった）。
  void release(String accountKey, String url) {
    final key = _keyOf(accountKey, url);
    final remaining = (_interest[key] ?? 0) - 1;
    if (remaining <= 0) {
      _interest.remove(key);
    } else {
      _interest[key] = remaining;
    }
  }

  static Future<Post?> _lookup(SearchSupport search, String url) async {
    final results = await search.search(url);
    // URL が一致しないときは、解決した 1 件だけを採る。複数あるのは URL として
    // 解決されなかった（全文検索に回った）ときで、先頭は無関係な投稿になりうる。
    return results.posts.where((p) => p.url == url).firstOrNull ??
        (results.posts.length == 1 ? results.posts.single : null);
  }

  /// 同時に [concurrency] 本までにして [task] を走らせる。
  ///
  /// ⚠⚠ **枠は終わった側から待っている側へ直接渡す** (#1304)。以前は終わった側が
  /// `_running--` してから待っている側を起こし、起きた側が `_running++` していた。
  /// 起きるのは次のマイクロタスクなので、その間に来た新しい呼び出しが空いた枠を
  /// 取り、一瞬 `concurrency + 1` 本になっていた。渡すときは数を動かさない。
  Future<T> _throttled<T>(String key, Future<T> Function() task) async {
    if (_running >= concurrency) {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future; // 枠は渡されている（_running はそのまま）
    } else {
      _running++;
    }
    try {
      // 待っている間に画面から外れていたら引かない。
      if (!_interest.containsKey(key)) throw const _Cancelled();
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}

/// 待っている間に関心が 0 になった（画面から外れた）印。
class _Cancelled implements Exception {
  const _Cancelled();
}
