import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_backends/src/mastodon/streaming.dart';
import 'package:capsicum_backends/src/misskey/streaming.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1209: タグ TL の条件（すべて含む / いずれかを含む / 含まない）を、両 SNS へ
/// どう送るか。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter([this.bodies = const {}]);

  /// パスの末尾ごとの応答（無ければ空の配列）。
  final Map<String, Object> bodies;
  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return ResponseBody.fromString(
      jsonEncode(
        bodies.entries
                .where((e) => options.path.endsWith(e.key))
                .map((e) => e.value)
                .firstOrNull ??
            <Object>[],
      ),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('Mastodon', () {
    test('パスのタグ + any[] / all[] / none[] で送る', () async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      final http = _RecordingAdapter({
        '/tag/a': [_status('1')],
      });
      adapter.client.dio.httpClientAdapter = http;

      final posts = await adapter.getPostsByHashtag(
        HashtagQuery.parse('x?a+b!z'),
      );

      expect(posts, hasLength(1));
      // 投稿が返れば、問い合わせは 1 回だけ。
      final call = http.calls.single;
      expect(call.path, '/api/v1/timelines/tag/a');
      expect(call.queryParameters['any[]'], ['b']);
      expect(call.queryParameters['all[]'], ['x']);
      expect(call.queryParameters['none[]'], ['z']);
    });

    test('⚠⚠ 空だった回は、「いずれか」の残りのタグをパスへ回して引き直す', () async {
      // パスに置いたタグがサーバーに無いと、Mastodon は `any[]` を見ずに空を返す。
      // 「これから使われるタグ または 既にあるタグ」で前者が先頭の形。
      final adapter = await MastodonAdapter.create('mstdn.example');
      final http = _RecordingAdapter({
        '/tag/old': [_status('1')],
      });
      adapter.client.dio.httpClientAdapter = http;

      final posts = await adapter.getPostsByHashtag(
        HashtagQuery.parse('x?new+old!z'),
      );

      expect(posts, hasLength(1), reason: '既にあるタグの投稿が出る');
      expect(http.calls.map((c) => c.path), [
        '/api/v1/timelines/tag/new',
        '/api/v1/timelines/tag/old',
      ]);
      final retry = http.calls.last;
      expect(retry.queryParameters['any[]'], ['new']);
      expect(retry.queryParameters['all[]'], ['x']);
      expect(retry.queryParameters['none[]'], ['z']);
    });

    test('⚠ 本当に空の回でも、引き直しは「いずれか」の数で止まる', () async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      final http = _RecordingAdapter();
      adapter.client.dio.httpClientAdapter = http;

      expect(
        await adapter.getPostsByHashtag(HashtagQuery.parse('?a+b+c')),
        isEmpty,
      );
      expect(http.calls, hasLength(3));
    });

    test('⚠ 以前からの AND 指定は、今までどおりの形で送る', () async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      final http = _RecordingAdapter();
      adapter.client.dio.httpClientAdapter = http;

      await adapter.getPostsByHashtag(HashtagQuery.parse('nitiasa+precure'));

      final call = http.calls.single;
      expect(call.path, '/api/v1/timelines/tag/nitiasa');
      expect(call.queryParameters['all[]'], ['precure']);
      expect(call.queryParameters.containsKey('any[]'), isFalse);
      expect(call.queryParameters.containsKey('none[]'), isFalse);
    });

    test('含む側が無い条件では、サーバーへ問い合わせない', () async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      final http = _RecordingAdapter();
      adapter.client.dio.httpClientAdapter = http;

      expect(
        await adapter.getPostsByHashtag(HashtagQuery.parse('!x')),
        isEmpty,
      );
      expect(http.calls, isEmpty);
    });

    test('⚠ ストリームを張るのはタグ 1 つの条件だけ（複数タグは #1277）', () {
      expect(mastodonStreamTarget(const HashtagTab('precure'))?.tag, 'precure');
      for (final spec in ['a+b', '?a+b', 'a!x']) {
        expect(mastodonStreamTarget(HashtagTab(spec)), isNull, reason: spec);
      }
    });
  });

  group('Misskey', () {
    test('🔴 AND 指定を query で送る（以前は先頭のタグ 1 つしか送っていなかった）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RecordingAdapter();
      adapter.client.dio.httpClientAdapter = http;

      await adapter.getPostsByHashtag(HashtagQuery.parse('nitiasa+precure'));

      final body = http.calls.single.data as Map;
      expect(body['query'], [
        ['nitiasa', 'precure'],
      ]);
      expect(
        body.containsKey('tag'),
        isFalse,
        reason: '`tag` と `query` は併用できない。`tag` だと AND にならない',
      );
    });

    test('OR は外側、AND は内側', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RecordingAdapter();
      adapter.client.dio.httpClientAdapter = http;

      await adapter.getPostsByHashtag(HashtagQuery.parse('x?a+b!z'));

      expect((http.calls.single.data as Map)['query'], [
        ['a', 'x'],
        ['b', 'x'],
      ]);
    });

    test('ストリーミングの q も REST の query と同じ形', () {
      expect(misskeyStreamChannel(const HashtagTab('x?a+b!z'))?.params, {
        'q': [
          ['a', 'x'],
          ['b', 'x'],
        ],
      });
      expect(misskeyStreamChannel(const HashtagTab('a+b'))?.params, {
        'q': [
          ['a', 'b'],
        ],
      });
      expect(misskeyStreamChannel(const HashtagTab('!x')), isNull);
    });
  });
}

Map<String, dynamic> _status(String id) => {
  'id': id,
  'created_at': '2026-10-12T00:00:00Z',
  'account': {
    'id': '1',
    'username': 'alice',
    'acct': 'alice',
    'display_name': 'alice',
    'note': '',
    'avatar': '',
    'header': '',
    'followers_count': 0,
    'following_count': 0,
    'statuses_count': 0,
    'fields': <Map<String, dynamic>>[],
  },
  'content': '<p>x</p>',
  'visibility': 'public',
  'favourites_count': 0,
  'reblogs_count': 0,
  'replies_count': 0,
  'media_attachments': <Map<String, dynamic>>[],
};
