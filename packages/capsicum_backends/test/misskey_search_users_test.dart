import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1344: Misskey の `users/search` は「ユーザー名@ホスト」を解さず 0 件を返す。
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
  late MisskeyAdapter adapter;
  late _RecordingAdapter http;

  setUp(() async {
    adapter = await MisskeyAdapter.create('misskey.example');
    http = _RecordingAdapter();
    adapter.client.dio.httpClientAdapter = http;
  });

  Future<RequestOptions> search(String query, {int? limit}) async {
    await adapter.searchUsers(query, limit: limit);
    return http.calls.single;
  }

  group('完全な形は search-by-username-and-host へ回す', () {
    test('ユーザー名@ホスト', () async {
      final call = await search('test@remote.example', limit: 5);

      expect(call.path, endsWith('/api/users/search-by-username-and-host'));
      expect(call.data, containsPair('username', 'test'));
      expect(call.data, containsPair('host', 'remote.example'));
      expect(call.data, containsPair('limit', 5));
      expect((call.data as Map).containsKey('query'), isFalse);
    });

    test('先頭の @ と前後の空白を落とす', () async {
      final call = await search(' @test@remote.example ');

      expect(call.path, endsWith('/api/users/search-by-username-and-host'));
      expect(call.data, containsPair('username', 'test'));
      expect(call.data, containsPair('host', 'remote.example'));
    });

    test('⚠ 自分のサーバーは . に読み替える（大文字小文字を問わない）', () async {
      final call = await search('test@Misskey.Example');

      expect(call.data, containsPair('host', '.'));
    });
  });

  group('それ以外は従来どおり users/search', () {
    for (final query in [
      'test',
      '@test',
      'test@',
      '@remote.example',
      'a@b@c',
      'first last@example',
      'キュア@春',
    ]) {
      test('"$query"', () async {
        final call = await search(query);

        expect(call.path, endsWith('/api/users/search'));
        expect(call.data, containsPair('query', query));
      });
    }
  });
}
