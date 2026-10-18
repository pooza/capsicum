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

  group('quoteFallbackUrl', () {
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
  });

  group('stripQuoteFallback', () {
    test('⚠ Misskey の形は前の改行ごと外す', () {
      expect(stripQuoteFallback(misskeyBody), '<p>ほんぶん</p>');
    });

    test('Mastodon の形は段落ごと外す', () {
      expect(stripQuoteFallback(mastodonBody), '<p>ほんぶん</p>');
    });
  });

  group('quoteFallbackTarget', () {
    test('pending で引用元が無く、RE: があれば対象', () {
      expect(
        quoteFallbackTarget(
          _post('1', content: misskeyBody, state: QuoteState.pending),
        ),
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
          _post(
            '1',
            content: misskeyBody,
            state: QuoteState.pending,
            quote: _post('q'),
          ),
        ),
        isNull,
      );
      expect(
        quoteFallbackTarget(
          _post('1', content: '<p>x</p>', state: QuoteState.pending),
        ),
        isNull,
      );
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
