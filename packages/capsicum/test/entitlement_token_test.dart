import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:capsicum/src/constants.dart';
import 'package:capsicum/src/provider/supporter_purchase_provider.dart';
import 'package:capsicum/src/service/entitlement_token_store.dart';
import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:capsicum/src/util/sensitive_fields.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

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

  // capsicum-relay#89: relay は利用権の確認の枠が埋まっていると、**何も保存せずに**
  // 503（reason: verification_busy）で断る。送り直さないと購入が relay に載らない。
  group('PushRelayClient.issueEntitlementToken — relay が塞がっていた回', () {
    const busy = (
      503,
      '{"error":"Verification busy","reason":"verification_busy"}',
    );
    const issued = (
      201,
      '{"token":"et-abc","store":"apple","status":"active"}',
    );

    test('verification_busy の 503 は、間を置いて送り直す', () {
      fakeAsync((async) {
        final adapter = _ScriptedAdapter([busy, issued]);
        final client = PushRelayClient()..httpClientAdapterForTesting = adapter;
        Map<String, dynamic>? json;
        client
            .issueEntitlementToken(
              store: 'apple',
              purchaseId: 'tx-1',
              deviceId: 'install-1',
            )
            .then((value) => json = value);

        async.elapse(const Duration(milliseconds: 100));
        expect(adapter.calls, 1);
        expect(json, isNull, reason: '間を置かずに送り直している');

        async.elapse(const Duration(seconds: 3));
        expect(adapter.calls, 2);
        expect(json?['token'], 'et-abc');
      });
    });

    // ⚠⚠ 503 を一律に送り直さない。設定の欠落のような 503 は、待っても直らない。
    test('reason の無い 503 は送り直さない', () {
      fakeAsync((async) {
        final adapter = _ScriptedAdapter([
          (503, '{"error":"Relay is not configured"}'),
          issued,
        ]);
        final client = PushRelayClient()..httpClientAdapterForTesting = adapter;
        Object? error;
        client
            .issueEntitlementToken(
              store: 'apple',
              purchaseId: 'tx-1',
              deviceId: 'install-1',
            )
            .then<void>((_) {}, onError: (Object e) => error = e);

        async.elapse(const Duration(seconds: 30));
        expect(adapter.calls, 1);
        expect(error, isA<DioException>());
      });
    });
  });

  // リリース PR の Codex P1（締めの回・2026-10-06）。
  group('EntitlementTokenStore — 書き換えの順序', () {
    test('⚠⚠ 書き換えは、呼ばれた順に 1 本ずつ実行する（遅い 1 本を追い越さない）', () async {
      final order = <String>[];
      // 先に呼ばれた遅い書き換え（＝ 古い値の保存）と、あとから呼ばれた速い
      // 書き換え（＝ 消去）。並べて走らせると、速いほうが先に終わる。
      final slow = EntitlementTokenStore.serializedForTesting(() async {
        order.add('slow:start');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        order.add('slow:end');
      });
      final fast = EntitlementTokenStore.serializedForTesting(() async {
        order.add('fast:start');
        order.add('fast:end');
      });
      await Future.wait([slow, fast]);

      expect(order, ['slow:start', 'slow:end', 'fast:start', 'fast:end']);
    });

    test('⚠ 1 本が失敗しても、次の書き換えは実行される', () async {
      final failed = EntitlementTokenStore.serializedForTesting<void>(
        () async => throw StateError('boom'),
      );
      await expectLater(failed, throwsStateError);

      var ran = false;
      await EntitlementTokenStore.serializedForTesting(() async => ran = true);
      expect(ran, isTrue);
    });

    test('⚠⚠ 保存と消去が、どちらも待ち行列を通っている（配線）', () {
      final source = File(
        'lib/src/service/entitlement_token_store.dart',
      ).readAsStringSync();
      for (final head in [
        'static Future<void> save(EntitlementToken token) {',
        'static Future<bool> clear() {',
      ]) {
        final at = source.indexOf(head);
        expect(at, greaterThan(0), reason: '$head が見つからない');
        expect(
          source.substring(at, at + head.length + 40),
          contains('return _serialized('),
          reason: '$head が待ち行列を通っていない',
        );
      }
    });
  });

  // リリース PR の Codex P1（2026-10-08）。
  group('EntitlementTokenStore — 初回の読みと書き換えの重なり', () {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );

    /// 読みだけを [reading] の結果で返す。書き換えはすぐ返す。
    /// ⚠ 関数で受ける（失敗の Future を先に作ると、聞き手が付く前に落ちる）。
    void mockStorage(Future<String?> Function() reading) {
      TestWidgetsFlutterBinding.ensureInitialized();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        return call.method == 'read' ? reading() : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      EntitlementTokenStore.resetCacheForTesting();
      addTearDown(EntitlementTokenStore.resetCacheForTesting);
    }

    test('🔴 読んでいる間に保存が済んだら、古い中身でキャッシュを上書きしない', () async {
      final reading = Completer<String?>();
      mockStorage(() => reading.future);

      final loading = EntitlementTokenStore.loadOrThrow();
      await EntitlementTokenStore.save(
        const EntitlementToken(token: 'et-new', store: 'apple'),
      );
      // 読みが返すのは、保存より前の中身（空）。
      reading.complete(null);

      expect((await loading)?.token, 'et-new');
      expect((await EntitlementTokenStore.loadOrThrow())?.token, 'et-new');
    });

    test('🔴 読んでいる間に消去が済んだら、消した token が戻らない', () async {
      final reading = Completer<String?>();
      mockStorage(() => reading.future);

      final loading = EntitlementTokenStore.loadOrThrow();
      await EntitlementTokenStore.clear();
      reading.complete('{"token":"et-old","store":"apple"}');

      expect(await loading, isNull);
      expect(await EntitlementTokenStore.loadOrThrow(), isNull);
    });

    test('🔴 読みが失敗で返っても、その間に済んだ保存を捨てない', () async {
      final reading = Completer<String?>();
      mockStorage(() => reading.future);

      final loading = EntitlementTokenStore.loadOrThrow();
      final loadingLenient = EntitlementTokenStore.load();
      await EntitlementTokenStore.save(
        const EntitlementToken(token: 'et-new', store: 'apple'),
      );
      reading.completeError(PlatformException(code: 'boom'));

      expect((await loading)?.token, 'et-new');
      expect((await loadingLenient)?.token, 'et-new');
    });

    test('対照群: 書き換えが無ければ、読みの失敗はそのまま投げる（確定させない）', () async {
      mockStorage(() => Future<String?>.error(PlatformException(code: 'boom')));

      await expectLater(EntitlementTokenStore.loadOrThrow(), throwsA(anything));
      expect(await EntitlementTokenStore.load(), isNull);
    });

    test('対照群: 重なりが無ければ、読んだ中身がそのまま入る', () async {
      mockStorage(() => Future.value('{"token":"et-old","store":"apple"}'));

      expect((await EntitlementTokenStore.loadOrThrow())?.token, 'et-old');
    });

    // #1247: 順序の守り方を「結果ごとの分岐」から「合流点 1 か所」にまとめた。
    // 上の 5 本が守っている振る舞いは変えていない。ここは作りの側を見る。
    test('⚠⚠ 読みの出口は、合流点を通ってからしか出ない（配線）', () {
      final source = maskComments(
        File('lib/src/service/entitlement_token_store.dart').readAsStringSync(),
      );
      final start = source.indexOf(
        'static Future<EntitlementToken?> loadOrThrow() async {',
      );
      final end = source.indexOf('static Future<void> save(', start);
      expect(start, greaterThan(0));
      expect(end, greaterThan(start), reason: '本体を切り出せていない');
      final body = source.substring(start, end);

      // 読みを待ったあとの出口は 3 つ: 合流点・失敗の投げ直し・確定した値。
      final afterRead = body.substring(body.indexOf('_gate.read('));
      expect(
        'if (_loaded) return _cached;'.allMatches(afterRead),
        hasLength(1),
        reason: '⚠ 合流点が複数ある ＝ 結果ごとの分岐へ戻っている',
      );
      // ⚠ catch の中で投げ直さない（合流点を飛ばす出口になる）。
      expect(afterRead, isNot(contains('rethrow')));
      // 合流点は、失敗の投げ直しより前。
      expect(
        afterRead.indexOf('if (_loaded) return _cached;'),
        lessThan(afterRead.indexOf('Error.throwWithStackTrace(')),
      );
    });
  });

  // #1247（リリース PR の Codex P2・2026-10-08）: 消去が失敗しても「消えた」と
  // 確定させていたので、再起動すると token が読み直されて戻っていた。
  group('EntitlementTokenStore — 消せなかった回', () {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    var deleteThrows = false;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      deleteThrows = false;
      final store = <String, String>{
        'entitlement_token_v1': '{"token":"et-kept","store":"apple"}',
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, Object?>() ?? {};
            final key = args['key'] as String?;
            switch (call.method) {
              case 'read':
                return store[key!];
              case 'delete':
                if (deleteThrows) throw PlatformException(code: 'boom');
                store.remove(key!);
                return null;
              default:
                return null;
            }
          });
      EntitlementTokenStore.resetCacheForTesting();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      EntitlementTokenStore.resetCacheForTesting();
    });

    test('前提: 消せたら true を返し、以降は持っていない', () async {
      expect((await EntitlementTokenStore.loadOrThrow())?.token, 'et-kept');
      expect(await EntitlementTokenStore.clear(), isTrue);
      expect(await EntitlementTokenStore.loadOrThrow(), isNull);
    });

    test('🔴 消せなかったら false を返し、キャッシュを「消えた」にしない', () async {
      expect((await EntitlementTokenStore.loadOrThrow())?.token, 'et-kept');
      deleteThrows = true;

      expect(await EntitlementTokenStore.clear(), isFalse);
      expect(
        (await EntitlementTokenStore.loadOrThrow())?.token,
        'et-kept',
        reason: '⚠ 直す前はここが null（画面は消えたと伝え、再起動で戻る）',
      );
    });

    test('⚠ まだ読んでいない状態で消せなかった回も、空に確定させない', () async {
      deleteThrows = true;

      expect(await EntitlementTokenStore.clear(), isFalse);
      expect((await EntitlementTokenStore.loadOrThrow())?.token, 'et-kept');
    });
  });

  // 2 回目の差分レビュー（2026-10-06）。
  group('利用権の発行 — 待ち時間と記録', () {
    test('⚠⚠ 発行は、relay がストアへ問い合わせる上限より長く待つ', () {
      fakeAsync((async) {
        final adapter = _ScriptedAdapter([
          (201, '{"token":"et-abc","store":"apple","purchase_id":"tx-1"}'),
        ]);
        final client = PushRelayClient()..httpClientAdapterForTesting = adapter;
        client.issueEntitlementToken(
          store: 'apple',
          purchaseId: 'tx-1',
          deviceId: 'install-1',
        );
        async.elapse(const Duration(milliseconds: 100));

        expect(adapter.receiveTimeouts, [kRelayEntitlementIssueReceiveTimeout]);
        // relay は Apple を本番 → サンドボックスの順に、それぞれ最大 15 秒引く。
        expect(
          kRelayEntitlementIssueReceiveTimeout,
          greaterThan(const Duration(seconds: 30)),
        );
      });
    });

    DioException failure(int status, Object? data) => DioException(
      requestOptions: RequestOptions(path: '/entitlements'),
      response: Response<Object?>(
        requestOptions: RequestOptions(path: '/entitlements'),
        statusCode: status,
        data: data,
      ),
      type: DioExceptionType.badResponse,
    );

    test('⚠⚠ 失敗の記録は、ステータスと「塞がっていた」で分かれる', () {
      final busy = entitlementIssueFingerprint(
        failure(503, {
          'error': 'Verification busy',
          'reason': 'verification_busy',
        }),
      );
      final unconfigured = entitlementIssueFingerprint(
        failure(503, {'error': 'Relay is not configured'}),
      );
      final unauthorized = entitlementIssueFingerprint(failure(401, null));
      final offline = entitlementIssueFingerprint(
        DioException(
          requestOptions: RequestOptions(path: '/entitlements'),
          type: DioExceptionType.connectionError,
        ),
      );

      expect(
        {
          busy.join('|'),
          unconfigured.join('|'),
          unauthorized.join('|'),
          offline.join('|'),
        },
        hasLength(4),
        reason: '同じ 1 件に畳まれている',
      );
      expect(busy, contains('verification_busy'));
      expect(unconfigured, isNot(contains('verification_busy')));
    });

    test('⚠ 応答の値をそのまま載せない（知っている語だけ通す）', () {
      expect(
        relayBusyReasonOf(failure(503, {'reason': 'verification_busy'})),
        'verification_busy',
      );
      expect(relayBusyReasonOf(failure(503, {'reason': 'x' * 200})), isNull);
      expect(relayBusyReasonOf(failure(503, 'plain text')), isNull);
      expect(relayBusyReasonOf(StateError('x')), isNull);
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

/// 決めておいた応答を順に返す。尽きたら最後の応答を返し続ける。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.responses);

  final List<(int, String)> responses;
  int calls = 0;
  final List<Duration?> receiveTimeouts = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (status, body) =
        responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    receiveTimeouts.add(options.receiveTimeout);
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
