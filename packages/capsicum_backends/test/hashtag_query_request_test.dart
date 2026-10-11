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
  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return ResponseBody.fromString(
      jsonEncode(<Object>[]),
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
      final http = _RecordingAdapter();
      adapter.client.dio.httpClientAdapter = http;

      await adapter.getPostsByHashtag(HashtagQuery.parse('x?a+b!z'));

      final call = http.calls.single;
      expect(call.path, '/api/v1/timelines/tag/a');
      expect(call.queryParameters['any[]'], ['b']);
      expect(call.queryParameters['all[]'], ['x']);
      expect(call.queryParameters['none[]'], ['z']);
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
