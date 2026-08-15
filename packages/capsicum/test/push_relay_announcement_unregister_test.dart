import 'dart:async';
import 'dart:typed_data';

import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #979 の回帰テスト。
///
/// お知らせ購読の解除 (`DELETE /announcement_subscriptions/:id`) は冪等操作で、
/// relay 側に対象が既に無い (404) 場合は成功として扱う。ここで飲まないと、
/// `AnnouncementSubscriptionService.disable` の catch が `scrubException` 経由で
/// error として Sentry (CAPSICUM-3G) に計上してしまう。
///
/// 404 以外の失敗 (500 等) は依然として rethrow することも固定する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('404 は冪等な成功として飲み込む (投げない)', () async {
    final client = PushRelayClient()
      ..httpClientAdapterForTesting = _StatusAdapter(404);

    await expectLater(client.unregisterAnnouncementSubscription(22), completes);
  });

  test('404 以外 (500) は DioException を rethrow する', () async {
    final client = PushRelayClient()
      ..httpClientAdapterForTesting = _StatusAdapter(500);

    await expectLater(
      client.unregisterAnnouncementSubscription(22),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'statusCode',
          500,
        ),
      ),
    );
  });
}

/// 常に指定 status を返す最小の dio アダプタ。ボディは空 JSON。
class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.statusCode);

  final int statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '',
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
