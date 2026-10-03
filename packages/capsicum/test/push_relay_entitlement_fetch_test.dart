import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 利用権の現在の状態を読む (#1123 / capsicum-relay#80)。
///
/// ⚠ ここで固定したいのは 3 つ。
///
/// 1. 🔴 **token を URL に載せない。**relay の nginx は素の `access_log` を
///    有効にしており、**リクエスト行に完全なパスが残る** —— ⚠⚠ **token は
///    そのまま利用権として使える capability** なので、平文でログに溜まる
///    （capsicum-relay#81 の Codex P2）
/// 2. ⚠⚠ **404 は「失効」ではない**ので null に畳む。呼び出し側で混ぜないこと ——
///    「知らない token」は端末の保存が壊れた / 消された、「失効」は解約や支払い
///    失敗で、**案内が違う**
/// 3. それ以外の失敗は投げる（黙って「未購入」に見せない）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('🔴 token を URL に載せず、ヘッダで送る', () async {
    final spy = _SpyAdapter(200, body: '{"token":"t","store":"apple"}');
    final client = PushRelayClient()..httpClientAdapterForTesting = spy;

    await client.fetchEntitlement('super-secret-token');

    expect(spy.path, '/entitlements');
    expect(
      spy.path,
      isNot(contains('super-secret-token')),
      reason: 'nginx の access log に平文で残る',
    );
    expect(spy.headers['X-Entitlement-Token'], 'super-secret-token');
  });

  test('応答をそのまま返す', () async {
    final spy = _SpyAdapter(
      200,
      body: jsonEncode({'token': 't', 'store': 'apple', 'status': 'active'}),
    );
    final client = PushRelayClient()..httpClientAdapterForTesting = spy;

    final json = await client.fetchEntitlement('t');

    expect(json?['status'], 'active');
  });

  // ⚠⚠ 「知らない token」と「失効」を混ぜない。
  test('404 は null（失効ではない）', () async {
    final client = PushRelayClient()
      ..httpClientAdapterForTesting = _SpyAdapter(404);

    expect(await client.fetchEntitlement('gone'), isNull);
  });

  // ⚠ 通信の失敗で「未購入」に見せない。呼び出し側が手元の値を残せるよう投げる。
  test('500 は投げる', () async {
    final client = PushRelayClient()
      ..httpClientAdapterForTesting = _SpyAdapter(500);

    await expectLater(
      client.fetchEntitlement('t'),
      throwsA(isA<DioException>()),
    );
  });
}

/// 要求の経路とヘッダを覚えるアダプタ。
class _SpyAdapter implements HttpClientAdapter {
  _SpyAdapter(this.statusCode, {this.body = '{}'});

  final int statusCode;
  final String body;
  String? path;
  Map<String, String> headers = const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    path = options.path;
    headers = {
      for (final e in options.headers.entries) e.key: e.value.toString(),
    };
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
