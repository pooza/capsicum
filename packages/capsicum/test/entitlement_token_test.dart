import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:capsicum/src/service/entitlement_token_store.dart';
import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:capsicum/src/util/sensitive_fields.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 有償リレーの利用権トークン (#597 / #1121)。
///
/// ⚠⚠ **ここで固定したいのは 3 点。**
///
/// 1. ⚠⚠ **token を持たなくても `/register` は従来どおり通る**（この段階では
///    誰も拒まれない。載せるフィールドが増えただけ）
/// 2. 持っていれば `entitlement_token` として載る
/// 3. ⚠ **token と purchase_id が Sentry へ出ない**
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PushRelayClient.register — #1121 利用権トークンの同梱', () {
    // ⚠⚠ **いちばん大事な固定。**フェーズ 1 は「観測のみ・誰も拒まない」。
    test('token が無ければ entitlement_token を載せない（登録は通る）', () async {
      final adapter = _CapturingAdapter();
      final client = PushRelayClient()..httpClientAdapterForTesting = adapter;

      final result = await client.register(
        token: 'device-token',
        deviceType: 'ios',
        account: 'alice@example.test',
        server: 'example.test',
        deviceId: 'install-1',
      );

      expect(result['push_token'], 'pt-1');
      expect(adapter.lastBody, isNot(contains('entitlement_token')));
    });

    test('token があれば entitlement_token として載る', () async {
      final adapter = _CapturingAdapter();
      final client = PushRelayClient()..httpClientAdapterForTesting = adapter;

      await client.register(
        token: 'device-token',
        deviceType: 'ios',
        account: 'alice@example.test',
        server: 'example.test',
        deviceId: 'install-1',
        entitlementToken: 'et-abc',
      );

      expect(adapter.lastJson['entitlement_token'], 'et-abc');
    });

    // ⚠ 空文字を載せない（relay 側は `.empty?` で「送っていない」と扱うが、
    // 送らないほうが意図が明確）。
    test('deviceId と同じく null のフィールドは省かれる', () async {
      final adapter = _CapturingAdapter();
      final client = PushRelayClient()..httpClientAdapterForTesting = adapter;

      await client.register(
        token: 'device-token',
        deviceType: 'ios',
        account: 'alice@example.test',
        server: 'example.test',
      );

      expect(adapter.lastJson.containsKey('device_id'), isFalse);
      expect(adapter.lastJson.containsKey('entitlement_token'), isFalse);
    });
  });

  group('PushRelayClient.issueEntitlementToken — #1121 発行', () {
    test('store / purchase_id / device_id を送り、応答をそのまま返す', () async {
      final adapter = _CapturingAdapter(
        body: jsonEncode({
          'token': 'et-abc',
          'store': 'apple',
          'purchase_id': 'tx-1',
          'product_id': 'supporter.relay.monthly',
          'status': 'unverified',
        }),
      );
      final client = PushRelayClient()..httpClientAdapterForTesting = adapter;

      final json = await client.issueEntitlementToken(
        store: 'apple',
        purchaseId: 'tx-1',
        deviceId: 'install-1',
        productId: 'supporter.relay.monthly',
      );

      expect(adapter.lastPath, '/entitlements');
      expect(adapter.lastJson['store'], 'apple');
      expect(adapter.lastJson['purchase_id'], 'tx-1');
      expect(adapter.lastJson['device_id'], 'install-1');
      expect(json['token'], 'et-abc');
    });
  });

  group('EntitlementToken — 応答の読み取り', () {
    test('relay の応答から作れる', () {
      final token = EntitlementToken.fromRelay({
        'token': 'et-abc',
        'store': 'apple',
        'purchase_id': 'tx-1',
        'product_id': 'supporter.relay.monthly',
        'status': 'active',
        'expires_at': '2026-10-28 00:00:00',
        'environment': 'Production',
      });

      expect(token, isNotNull);
      expect(token!.token, 'et-abc');
      expect(token.store, 'apple');
      expect(token.status, 'active');
    });

    // ⚠ token が無い応答を「持っている」と誤解しない。
    test('token が無い / 空なら null', () {
      expect(EntitlementToken.fromRelay(null), isNull);
      expect(EntitlementToken.fromRelay({'store': 'apple'}), isNull);
      expect(
        EntitlementToken.fromRelay({'token': '', 'store': 'apple'}),
        isNull,
      );
    });

    test('JSON へ往復できる', () {
      const token = EntitlementToken(
        token: 'et-abc',
        store: 'google',
        purchaseId: 'pt-1',
        status: 'grace',
      );
      final round = EntitlementToken.fromRelay(
        jsonDecode(jsonEncode(token.toJson())) as Map<String, dynamic>,
      );

      expect(round!.token, 'et-abc');
      expect(round.store, 'google');
      expect(round.purchaseId, 'pt-1');
      expect(round.status, 'grace');
    });

    // ⚠⚠ **toString に token を出さない。**debugPrint は release / profile で
    // breadcrumb になる。
    test('toString に token と purchase_id を出さない', () {
      const token = EntitlementToken(
        token: 'et-secret-value',
        store: 'apple',
        purchaseId: 'tx-secret',
        productId: 'supporter.relay.monthly',
        status: 'active',
      );

      expect(token.toString(), isNot(contains('et-secret-value')));
      expect(token.toString(), isNot(contains('tx-secret')));
      expect(token.toString(), contains('supporter.relay.monthly'));
    });
  });

  group('isSensitiveFieldName — #1121 Sentry へ出さない', () {
    // ⚠⚠ **`token` を載せても `entitlement_token` は拾えない。**判定は完全一致か
    // `[名前]` / `.名前` の末尾一致だけで、部分一致ではない。
    test('entitlement_token と purchase_id が伏せられる', () {
      expect(isSensitiveFieldName('entitlement_token'), isTrue);
      expect(isSensitiveFieldName('purchase_id'), isTrue);
      expect(isSensitiveFieldName('ENTITLEMENT_TOKEN'), isTrue);
    });

    // ⚠ この検査が空振りしないことの確認 —— `token` の登録だけでは
    // `entitlement_token` は通ってしまう、という判定の性質そのものを固定する。
    test('部分一致では拾わない（だから個別に登録が要る）', () {
      expect(isSensitiveFieldName('token'), isTrue);
      expect(isSensitiveFieldName('some_token_like_name'), isFalse);
      expect(isSensitiveFieldName('tokenish'), isFalse);
    });

    test('既存のクレデンシャル系は従来どおり伏せられる', () {
      for (final key in const [
        'i',
        'access_token',
        'refresh_token',
        'client_secret',
        'p256dh',
        'auth',
        'endpoint',
        'publickey',
        'privatekey',
        'subscription[keys][p256dh]',
      ]) {
        expect(isSensitiveFieldName(key), isTrue, reason: key);
      }
    });

    test('無関係なフィールドは伏せない', () {
      for (final key in const ['account', 'server', 'device_type', 'store']) {
        expect(isSensitiveFieldName(key), isFalse, reason: key);
      }
    });
  });
}

/// 送ったリクエストの body を覚える最小の dio アダプタ。
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({this.body = '{"id":1,"push_token":"pt-1"}'});

  final String body;
  String? lastPath;
  String? lastBody;

  Map<String, dynamic> get lastJson =>
      jsonDecode(lastBody ?? '{}') as Map<String, dynamic>;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastBody = jsonEncode(options.data);
    return ResponseBody.fromString(
      body,
      201,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
