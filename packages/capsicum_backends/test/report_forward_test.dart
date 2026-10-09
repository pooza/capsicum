import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1203: 通報をリモートのサーバーへ転送できる。
///
/// ⚠ **`forward` を送らなくても通報は 200 で通る。**自分のサーバーの管理者には
/// 届くので、相手のサーバーへ届いていないことに気付けない。実際に飛んだ
/// リクエストの本文を見る。
class _Recorder implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _body(RequestOptions options) =>
    options.data as Map<String, dynamic>;

void main() {
  group('Mastodon', () {
    late MastodonAdapter adapter;
    late _Recorder recorder;

    setUp(() async {
      adapter = await MastodonAdapter.create('example.com');
      recorder = _Recorder();
      adapter.client.dio.httpClientAdapter = recorder;
    });

    test('投稿の通報: forward を指定すると本文に載る', () async {
      await adapter.reportPost('100', '7', comment: 'spam', forward: true);

      final request = recorder.requests.single;
      expect(request.path, '/api/v1/reports');
      expect(_body(request), {
        'account_id': '7',
        'status_ids': ['100'],
        'comment': 'spam',
        'forward': true,
      });
    });

    test('ユーザーの通報: forward を指定すると本文に載る', () async {
      await adapter.reportUser('7', forward: true);

      expect(_body(recorder.requests.single), {
        'account_id': '7',
        'forward': true,
      });
    });

    test('指定しなければ forward を送らない（従来と同じ本文）', () async {
      await adapter.reportPost('100', '7');
      await adapter.reportUser('7');

      expect(_body(recorder.requests[0]).containsKey('forward'), isFalse);
      expect(_body(recorder.requests[1]).containsKey('forward'), isFalse);
    });

    test('リモートの相手には転送先のサーバーを返す', () {
      const remote = User(id: '1', username: 'alice', host: 'remote.example');
      expect(adapter.reportForwardHost(remote), 'remote.example');
    });

    test('⚠ ローカルの相手には返さない（host には自分のサーバーが入っている）', () {
      const local = User(id: '2', username: 'bob', host: 'example.com');
      expect(adapter.reportForwardHost(local), isNull);
    });

    test('host が無い / 空の相手にも返さない', () {
      expect(
        adapter.reportForwardHost(const User(id: '3', username: 'c')),
        isNull,
      );
      expect(
        adapter.reportForwardHost(const User(id: '4', username: 'd', host: '')),
        isNull,
      );
    });
  });

  group('Misskey', () {
    test('⚠ リモートの相手でも返さない（通報者が転送を指定する口が無い）', () async {
      final adapter = await MisskeyAdapter.create('example.com');
      const remote = User(id: '1', username: 'alice', host: 'remote.example');
      expect(adapter.reportForwardHost(remote), isNull);
    });
  });
}
