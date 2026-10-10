import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1202: Mastodon の一覧 3 経路が、サーバーの既定件数で黙って打ち切られない
/// ことを固定する。
///
/// ⚠ **打ち切りはエラーにならない。**`limit` / `offset` / `max_id` を送らない
/// 実装へ戻っても応答は 200 で、「それだけしか無い」ように見える。なので
/// 結果の件数ではなく、**実際に飛んだリクエストのパラメータ**を見る。
class _Recorder implements HttpClientAdapter {
  _Recorder(this.respond);

  /// リクエストを受けて (本文, Link ヘッダ) を返す。
  final (Object, String?) Function(RequestOptions options) respond;

  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (body, link) = respond(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (link != null) 'link': [link],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String? _query(RequestOptions options, String name) =>
    options.uri.queryParameters[name];

Map<String, dynamic> _scheduled(int n) => {
  'id': '$n',
  'scheduled_at': '2026-12-01T00:00:00.000Z',
  'params': {'text': 'post $n'},
  'media_attachments': <Object>[],
};

String _nextLink(String maxId) =>
    '<https://example.com/api/v1/scheduled_statuses?max_id=$maxId>; rel="next"';

void main() {
  group('リストのメンバー', () {
    test('limit=0 を送る（送らないと 40 人で切れる）', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder((_) => (<Object>[], null));
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.getListAccounts('7');

      final request = recorder.requests.single;
      expect(request.path, '/api/v1/lists/7/accounts');
      expect(_query(request, 'limit'), '0');
    });
  });

  group('予約投稿', () {
    test('Link の max_id を辿って 2 ページ目まで読む', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder((options) {
        // 1 ページ目は 40 件 + 続きあり、2 ページ目は 1 件で終端。
        if (_query(options, 'max_id') == null) {
          return ([for (var i = 41; i > 1; i--) _scheduled(i)], _nextLink('2'));
        }
        return ([_scheduled(1)], null);
      });
      adapter.client.dio.httpClientAdapter = recorder;

      final posts = await adapter.getScheduledPosts();

      expect(posts, hasLength(41));
      expect(posts.last.id, '1');
      expect(recorder.requests, hasLength(2));
      // ⚠ 既定の 20 ではなく上限の 40 で引く。
      expect(_query(recorder.requests[0], 'limit'), '40');
      expect(_query(recorder.requests[0], 'max_id'), isNull);
      expect(_query(recorder.requests[1], 'limit'), '40');
      expect(_query(recorder.requests[1], 'max_id'), '2');
    });

    test('Link が無ければ 1 回で終わる', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder((_) => ([_scheduled(1)], null));
      adapter.client.dio.httpClientAdapter = recorder;

      final posts = await adapter.getScheduledPosts();

      expect(posts, hasLength(1));
      expect(recorder.requests, hasLength(1));
    });

    test('Link が同じ max_id を返し続けても回り続けない', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder((_) => ([_scheduled(1)], _nextLink('9')));
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.getScheduledPosts();

      // 1 回目（max_id 無し）→ 2 回目（max_id=9）で、次も 9 なので止まる。
      expect(recorder.requests, hasLength(2));
    });

    test('max_id が進み続けても、回数の上限で止まる', () async {
      final adapter = await MastodonAdapter.create('example.com');
      var n = 1000;
      final recorder = _Recorder((_) => ([_scheduled(n)], _nextLink('${n--}')));
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.getScheduledPosts();

      // サーバーの総数上限は 300 件 ＝ 40 件ずつで 8 回。余裕を見て 10 回。
      expect(recorder.requests, hasLength(10));
    });
  });

  group('検索', () {
    Map<String, dynamic> emptyResults() => {
      'accounts': <Object>[],
      'statuses': <Object>[],
      'hashtags': <Object>[],
    };

    test('1 ページ目は offset を送らない（type 無しでは効かない）', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder((_) => (emptyResults(), null));
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.search('precure');

      final request = recorder.requests.single;
      expect(request.path, '/api/v2/search');
      expect(_query(request, 'limit'), '${adapter.searchPageSize}');
      expect(_query(request, 'offset'), isNull);
      expect(_query(request, 'type'), isNull);
    });

    test('続きは type と offset を一緒に送る', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder((_) => (emptyResults(), null));
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.searchMore('precure', SearchKind.posts, offset: 20);

      final request = recorder.requests.single;
      expect(request.path, '/api/v2/search');
      expect(_query(request, 'q'), 'precure');
      expect(_query(request, 'type'), 'statuses');
      expect(_query(request, 'offset'), '20');
      expect(_query(request, 'limit'), '${adapter.searchPageSize}');
      // ⚠ URL の解決は続きを持たないので、続きでは送らない。
      expect(_query(request, 'resolve'), isNull);
    });

    test('種別は Mastodon の type 名へ写す', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder((_) => (emptyResults(), null));
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.searchMore('a', SearchKind.users, offset: 20);
      await adapter.searchMore('a', SearchKind.hashtags, offset: 40);

      expect(_query(recorder.requests[0], 'type'), 'accounts');
      expect(_query(recorder.requests[1], 'type'), 'hashtags');
      expect(_query(recorder.requests[1], 'offset'), '40');
    });

    test('続きの結果は指定した種別だけが埋まる', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder(
        (_) => (
          {
            'accounts': <Object>[],
            'statuses': <Object>[],
            'hashtags': [
              {'name': 'precure'},
              {'name': 'delmulin'},
            ],
          },
          null,
        ),
      );
      adapter.client.dio.httpClientAdapter = recorder;

      final more = await adapter.searchMore(
        'a',
        SearchKind.hashtags,
        offset: 20,
      );

      expect(more.hashtags, ['precure', 'delmulin']);
      expect(more.users, isEmpty);
      expect(more.posts, isEmpty);
    });
  });
}
