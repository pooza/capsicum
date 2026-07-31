import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #895: チャンネル内へのリノート。
///
/// Misskey は `notes/create` の `channelId` でリノート先チャンネルを指定する。
/// 通常のリノート（チャンネル指定なし）と撃ち分けられていること、チャンネル
/// 投稿の公開範囲はチャンネルが決めるので visibility を送らないことを担保する。
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.body);

  final Object body;
  Map<String, dynamic>? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = Map<String, dynamic>.from(options.data as Map);
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

const _createdNote = <String, dynamic>{
  'createdNote': {
    'id': 'renote1',
    'createdAt': '2026-07-31T00:00:00.000Z',
    'userId': 'user1',
    'user': {'id': 'user1', 'username': 'me'},
    'visibility': 'public',
    'renoteCount': 0,
    'repliesCount': 0,
    'channelId': 'ch1',
    'channel': {'id': 'ch1', 'name': 'capsicum'},
  },
};

void main() {
  group('MisskeyAdapter.repeatPostToChannel (#895)', () {
    test('channelId を付けてリノートする（visibility は送らない）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _CapturingAdapter(_createdNote);
      adapter.client.dio.httpClientAdapter = http;

      final post = await adapter.repeatPostToChannel('note1', channelId: 'ch1');

      expect(http.lastRequest?['renoteId'], 'note1');
      expect(http.lastRequest?['channelId'], 'ch1');
      expect(http.lastRequest?.containsKey('visibility'), isFalse);
      expect(post.id, 'renote1');
      expect(post.channelId, 'ch1');
    });

    test('通常のリノートは channelId を送らない（チャンネル外に出る）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _CapturingAdapter(_createdNote);
      adapter.client.dio.httpClientAdapter = http;

      await adapter.repeatPost('note1', visibility: PostScope.unlisted);

      expect(http.lastRequest?['renoteId'], 'note1');
      expect(http.lastRequest?.containsKey('channelId'), isFalse);
      expect(http.lastRequest?['visibility'], 'home');
    });
  });
}
