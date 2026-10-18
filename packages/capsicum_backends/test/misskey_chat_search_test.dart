import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1188: Misskey のチャットのメッセージ検索（`chat/messages/search`）。
class _Recorder implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final Object body = switch (options.path) {
      '/api/i' => {'id': 'me', 'username': 'me'},
      '/api/chat/messages/search' => [
        {
          'id': 'm1',
          'createdAt': '2026-10-18T00:00:00.000Z',
          'fromUserId': 'u1',
          'fromUser': {'id': 'u1', 'username': 'alice'},
          'toUserId': 'me',
          'text': 'ダイの大冒険',
          'reactions': <Object>[],
        },
      ],
      _ => <String, dynamic>{},
    };
    return ResponseBody.fromString(
      jsonEncode(body),
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
  Map<String, dynamic> bodyOf(RequestOptions r) =>
      r.data as Map<String, dynamic>;

  test('相手を指定して検索する（上限 100 件・roomId は送らない）', () async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    final http = _Recorder();
    adapter.client.dio.httpClientAdapter = http;

    final results = await adapter.searchChatMessages(query: 'ダイ', userId: 'u1');

    final request = http.requests.singleWhere(
      (r) => r.path == '/api/chat/messages/search',
    );
    final body = bodyOf(request);
    expect(body['query'], 'ダイ');
    expect(body['limit'], 100);
    expect(body['userId'], 'u1');
    expect(body.containsKey('roomId'), isFalse);

    expect(results.single.id, 'm1');
    expect(results.single.text, 'ダイの大冒険');
    expect(results.single.fromUser.username, 'alice');
  });

  test('ルームを指定して検索する', () async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    final http = _Recorder();
    adapter.client.dio.httpClientAdapter = http;

    await adapter.searchChatMessages(query: 'ダイ', roomId: 'r1');

    final body = bodyOf(
      http.requests.singleWhere((r) => r.path == '/api/chat/messages/search'),
    );
    expect(body['roomId'], 'r1');
    expect(body.containsKey('userId'), isFalse);
  });
}
