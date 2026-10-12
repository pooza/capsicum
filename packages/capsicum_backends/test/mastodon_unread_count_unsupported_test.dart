import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1267: 未読数の口（`/api/v1/notifications/unread_count`）が無いサーバーへ、
/// 打ち続けない。Mastodon 4.3 未満では 404 になり、バッジの更新のたび
/// （30 秒ごと）に同じ 404 を打っていた。
class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status);

  int status;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      jsonEncode(status == 200 ? {'count': 7} : {'error': 'x'}),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('口があれば、サーバーの数をそのまま返す', () async {
    final adapter = await MastodonAdapter.create('mstdn.example');
    final http = _StatusAdapter(200);
    adapter.client.dio.httpClientAdapter = http;

    expect(await adapter.getUnreadNotificationCount(), 7);
    expect(await adapter.getUnreadNotificationCount(), 7);
    expect(http.calls, 2);
  });

  test('⚠⚠ 404 なら 0 を返し、以後は問い合わせない', () async {
    final adapter = await MastodonAdapter.create('mstdn.example');
    final http = _StatusAdapter(404);
    adapter.client.dio.httpClientAdapter = http;

    expect(await adapter.getUnreadNotificationCount(), 0);
    expect(await adapter.getUnreadNotificationCount(), 0);
    expect(await adapter.getUnreadNotificationCount(), 0);
    expect(http.calls, 1, reason: '以前は 30 秒ごとに 404 を打ち続けていた');
  });

  test('⚠⚠ 一時的な失敗（401 / 429 / 503）では「口が無い」と読まない', () async {
    for (final status in [401, 429, 503]) {
      final adapter = await MastodonAdapter.create('mstdn.example');
      final http = _StatusAdapter(status);
      adapter.client.dio.httpClientAdapter = http;

      await expectLater(
        adapter.getUnreadNotificationCount(),
        throwsA(isA<DioException>()),
        reason: '$status',
      );
      // 直ったら、次の回は数が取れる（立てっぱなしにしていない）。
      http.status = 200;
      expect(await adapter.getUnreadNotificationCount(), 7, reason: '$status');
    }
  });
}
