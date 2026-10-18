import 'dart:async';

import 'package:capsicum/src/ui/util/quote_fallback.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1269: Misskey からの引用を、Mastodon で引用として見せる。
class _Search with SearchSupport {
  final calls = <String>[];
  final pending = <String, Completer<SearchResults>>{};
  int running = 0;
  int maxRunning = 0;

  @override
  Future<SearchResults> search(String query) async {
    calls.add(query);
    running++;
    if (running > maxRunning) maxRunning = running;
    try {
      return await (pending[query] = Completer<SearchResults>()).future;
    } finally {
      running--;
    }
  }

  void answer(String url, {Post? post, Object? error}) {
    final completer = pending.remove(url)!;
    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(SearchResults(posts: [?post]));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImmediateSearch with SearchSupport {
  final calls = <String>[];

  @override
  Future<SearchResults> search(String query) async {
    calls.add(query);
    return SearchResults(posts: [_post('q${calls.length}')]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ManySearch with SearchSupport {
  @override
  Future<SearchResults> search(String query) async =>
      SearchResults(posts: [_post('a'), _post('b')]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Post _post(String id, {String? content, QuoteState? state, Post? quote}) =>
    Post(
      id: id,
      postedAt: DateTime.utc(2026, 10, 18),
      author: const User(id: 'u', username: 'u'),
      content: content,
      isHtml: true,
      quoteState: state,
      quote: quote,
      url: 'https://misskey.example/notes/$id',
    );

void main() {
  const misskeyBody =
      '<p>ほんぶん<br><br><span class="quote-inline">RE: '
      '<a href="https://misskey.example/notes/q1">https://misskey.example/notes/q1</a>'
      '</span></p>';
  const mastodonBody =
      '<p class="quote-inline">RE: <a href="https://mstdn.example/@a/1?x=1&amp;y=2">'
      '<span class="invisible">https://</span><span class="ellipsis">mstdn.example/@a/1</span>'
      '</a></p><p>ほんぶん</p>';
  // ⚠⚠ 2026-10-18 に 美食丼 が `mk.precure.fun/notes/asgx8182e3` について
  // 返した content そのまま（`quote` は null で届いた）。
  const misskeyParagraphBody =
      '<p>かわいい。<br>Misskeyで引用を行うテスト。</p><p><a href="https://mk.precure.fun/tags/precure_fun" rel="nofollow noopener" target="_blank">#precure_fun</a></p>'
      '<p><span class="quote-inline">RE: <a href="https://precure.ml/users/mikabot/statuses/117459886495203098" rel="nofollow noopener" target="_blank">https://precure.ml/users/mikabot/statuses/117459886495203098</a></span></p>';

  group('quoteFallbackUrl', () {
    test('⚠⚠ Misskey の今の形（span だけの段落）', () {
      expect(
        quoteFallbackUrl(misskeyParagraphBody),
        'https://precure.ml/users/mikabot/statuses/117459886495203098',
      );
    });

    test('Misskey の形（<span class="quote-inline">）', () {
      expect(quoteFallbackUrl(misskeyBody), 'https://misskey.example/notes/q1');
    });

    test('Mastodon の形（<p class="quote-inline">・入れ子の span・&amp;）', () {
      expect(
        quoteFallbackUrl(mastodonBody),
        'https://mstdn.example/@a/1?x=1&y=2',
      );
    });

    test('無ければ null', () {
      expect(quoteFallbackUrl('<p>RE: ふつうの本文</p>'), isNull);
      expect(quoteFallbackUrl(null), isNull);
    });

    test('⚠ http(s) 以外の href は拾わない（全文検索に回って別の投稿が出る）', () {
      expect(
        quoteFallbackUrl(
          '<p>x<br><br><span class="quote-inline">RE: '
          '<a href="xmpp:someone">someone</a></span></p>',
        ),
        isNull,
      );
      expect(
        quoteFallbackUrl(
          '<p class="quote-inline">RE: <a href="ふつうの言葉">x</a></p>',
        ),
        isNull,
      );
    });
  });

  group('stripQuoteFallback', () {
    test('⚠ Misskey の形は前の改行ごと外す', () {
      expect(stripQuoteFallback(misskeyBody), '<p>ほんぶん</p>');
    });

    test('Mastodon の形は段落ごと外す', () {
      expect(stripQuoteFallback(mastodonBody), '<p>ほんぶん</p>');
    });

    test('⚠ span だけの段落は、空の <p></p> を残さず段落ごと外す', () {
      final stripped = stripQuoteFallback(misskeyParagraphBody);
      expect(stripped, isNot(contains('quote-inline')));
      expect(stripped, isNot(contains('<p></p>')));
      expect(stripped, endsWith('#precure_fun</a></p>'));
    });
  });

  group('quoteFallbackTarget', () {
    test('⚠⚠ 引用の状態が無い（Mastodon が quote を null で返す）なら対象', () {
      expect(
        quoteFallbackTarget(_post('1', content: misskeyParagraphBody)),
        'https://precure.ml/users/mikabot/statuses/117459886495203098',
      );
    });

    test('⚠⚠ 承認待ち・却下・取り消し・削除・見せられないは補わない', () {
      for (final state in [
        QuoteState.pending,
        QuoteState.rejected,
        QuoteState.revoked,
        QuoteState.deleted,
        QuoteState.unauthorized,
      ]) {
        expect(
          quoteFallbackTarget(
            _post('1', content: misskeyParagraphBody, state: state),
          ),
          isNull,
          reason: '$state',
        );
      }
    });

    test('状態が無く、引用元が無く、RE: があれば対象（Misskey の今の形以外も）', () {
      expect(
        quoteFallbackTarget(_post('1', content: misskeyBody)),
        'https://misskey.example/notes/q1',
      );
    });

    test('承認済み・引用元が届いている・RE: が無いものは対象外', () {
      expect(
        quoteFallbackTarget(
          _post('1', content: misskeyBody, state: QuoteState.accepted),
        ),
        isNull,
      );
      expect(
        quoteFallbackTarget(
          _post('1', content: misskeyBody, quote: _post('q')),
        ),
        isNull,
      );
      expect(quoteFallbackTarget(_post('1', content: '<p>x</p>')), isNull);
    });
  });

  group('QuoteFallbackResolver', () {
    test('⚠⚠ 同じアカウントの同じ URL は 1 回しか引かない', () async {
      final search = _Search();
      final resolver = QuoteFallbackResolver();
      final first = resolver.resolve('me', search, 'u1');
      final second = resolver.resolve('me', search, 'u1');
      await Future<void>.delayed(Duration.zero);
      search.answer('u1', post: _post('q1'));

      expect((await first)?.id, 'q1');
      expect((await second)?.id, 'q1');
      expect(search.calls, ['u1']);
    });

    test('⚠ アカウントが違えば別に引く（id はサーバーのもの）', () async {
      final search = _ImmediateSearch();
      final resolver = QuoteFallbackResolver();
      await resolver.resolve('a', search, 'u1');
      await resolver.resolve('b', search, 'u1');
      await resolver.resolve('a', search, 'u1');

      expect(search.calls, ['u1', 'u1'], reason: 'a の 2 回目は持っている結果');
    });

    test('⚠⚠ 同時に引くのは決めた本数まで', () async {
      final search = _Search();
      final resolver = QuoteFallbackResolver(concurrency: 2);
      final futures = [
        for (var i = 0; i < 5; i++) resolver.resolve('me', search, 'u$i'),
      ];
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
        expect(search.running, lessThanOrEqualTo(2));
        search.answer(search.pending.keys.first, post: _post('q$i'));
      }
      await Future.wait(futures);
      expect(search.maxRunning, 2);
      expect(search.calls, hasLength(5));
    });

    test('⚠ URL が一致せず複数届いたら採らない（全文検索の先頭は無関係）', () async {
      final resolver = QuoteFallbackResolver();
      final many = _ManySearch();
      expect(await resolver.resolve('me', many, 'https://x.example/1'), isNull);
      expect(
        (await resolver.resolve(
          'me',
          many,
          'https://misskey.example/notes/b',
        ))?.id,
        'b',
        reason: 'URL が一致するものは採る',
      );
    });

    test('⚠ 通信の失敗は持たず、次は引き直す（見つからないは持つ）', () async {
      final search = _Search();
      final resolver = QuoteFallbackResolver();

      final failed = resolver.resolve('me', search, 'u1');
      await Future<void>.delayed(Duration.zero);
      search.answer('u1', error: Exception('network'));
      expect(await failed, isNull);

      final retried = resolver.resolve('me', search, 'u1');
      await Future<void>.delayed(Duration.zero);
      search.answer('u1');
      expect(await retried, isNull, reason: '見つからない');

      await resolver.resolve('me', search, 'u1');
      expect(search.calls, ['u1', 'u1'], reason: '見つからないは持つ');
    });
  });
}
