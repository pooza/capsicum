import 'dart:async';
import 'dart:typed_data';

import 'package:capsicum/src/service/push_registration_service.dart';
import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1262（capsicum-relay#91）: 登録解除で、端末の ID を一緒に送る。
///
/// relay の `DELETE /register/:id` は連番の id と共有シークレットだけで叩ける。
/// relay は `X-Device-Id` を行の `device_id` と照合するので、**送らない版が
/// 残っているあいだは、relay が「送ってこない要求」を拒めない。**
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PushRelayClient.unregister', () {
    test('⚠⚠ 端末の ID をヘッダで送る', () async {
      final adapter = _RecordingAdapter();
      final client = PushRelayClient()..httpClientAdapterForTesting = adapter;

      await client.unregister(42, deviceId: 'device-a');

      final request = adapter.requests.single;
      expect(request.method, 'DELETE');
      expect(request.path, '/register/42');
      expect(request.headers['X-Device-Id'], 'device-a');
      expect(
        request.uri.toString(),
        isNot(contains('device-a')),
        reason: '⚠ URL に載せない（アクセスログに残る）',
      );
    });

    test('ID が無い / 空ならヘッダを省く（解除は送る）', () async {
      final adapter = _RecordingAdapter();
      final client = PushRelayClient()..httpClientAdapterForTesting = adapter;

      await client.unregister(1);
      await client.unregister(2, deviceId: '');

      expect(adapter.requests, hasLength(2));
      for (final request in adapter.requests) {
        expect(request.headers.containsKey('X-Device-Id'), isFalse);
      }
    });
  });

  group('PushRegistrationService.unregisterDevice', () {
    test('⚠⚠ 全部の行に、同じ端末の ID を付けて送る', () async {
      final adapter = _RecordingAdapter();
      final client = PushRelayClient()..httpClientAdapterForTesting = adapter;
      var reads = 0;

      await PushRegistrationService.unregisterDevice(
        [3, 4],
        client: client,
        readDeviceId: () async {
          reads++;
          return 'device-a';
        },
      );

      expect(adapter.requests.map((r) => r.path), [
        '/register/3',
        '/register/4',
      ]);
      expect(
        adapter.requests.map((r) => r.headers['X-Device-Id']),
        everyElement('device-a'),
      );
      expect(reads, 1, reason: '端末の ID は 1 回だけ読む');
    });

    test('⚠ 端末の ID を読めなくても、解除は送る', () async {
      final adapter = _RecordingAdapter();
      final client = PushRelayClient()..httpClientAdapterForTesting = adapter;

      await PushRegistrationService.unregisterDevice(
        [5],
        client: client,
        readDeviceId: () async => throw StateError('keychain unreadable'),
      );

      final request = adapter.requests.single;
      expect(request.path, '/register/5');
      expect(request.headers.containsKey('X-Device-Id'), isFalse);
    });

    test('消す行が無ければ、端末の ID を読まない', () async {
      var reads = 0;

      await PushRegistrationService.unregisterDevice(
        const [],
        readDeviceId: () async {
          reads++;
          return 'device-a';
        },
      );

      expect(reads, 0);
    });
  });
}

/// 来た要求を記録して 200 を返すだけの dio アダプタ。
class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{"id":1}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
