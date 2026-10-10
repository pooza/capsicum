import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1207: 通知の未読数を、サーバーが数えた値で引く。
class _Recorder implements HttpClientAdapter {
  _Recorder(this.body);

  final Object body;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
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
  group('Mastodon', () {
    test('notifications/unread_count の count を返す', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder({'count': 7});
      adapter.client.dio.httpClientAdapter = recorder;

      expect(await adapter.getUnreadNotificationCount(), 7);

      final request = recorder.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '/api/v1/notifications/unread_count');
    });

    test('count が欠けていれば 0', () async {
      final adapter = await MastodonAdapter.create('example.com');
      adapter.client.dio.httpClientAdapter = _Recorder(<String, dynamic>{});

      expect(await adapter.getUnreadNotificationCount(), 0);
    });
  });

  group('Misskey', () {
    test('i の unreadNotificationsCount を返す', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final recorder = _Recorder({
        'id': 'u1',
        'username': 'alice',
        'unreadNotificationsCount': 3,
        'hasUnreadNotification': true,
      });
      adapter.client.dio.httpClientAdapter = recorder;

      expect(await adapter.getUnreadNotificationCount(), 3);

      final request = recorder.requests.single;
      expect(request.path, '/api/i');
      // ⚠ 数えるだけ。既読にする API は叩かない。
      expect(request.path, isNot(contains('mark-all-as-read')));
    });

    test('古いサーバーで欠けていれば 0（hasUnreadNotification から推測しない）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _Recorder({
        'id': 'u1',
        'username': 'alice',
        'hasUnreadNotification': true,
      });

      expect(await adapter.getUnreadNotificationCount(), 0);
    });
  });
}
