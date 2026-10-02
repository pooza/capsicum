import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

class _StaticAdapter implements HttpClientAdapter {
  _StaticAdapter(this.statusCode, this.body);

  final int statusCode;
  final Object body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body is String ? body as String : jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('MisskeyAdapter.subscribePush', () {
    test(
      'maps 400 ACCESS_DENIED to PushRegistrationNotSupportedException',
      () async {
        // Misskey upstream が /api/sw/register を secure:true で制限している
        // ときに返す本物相当の JSON（GHSA-7pxq-6xx9-xpgm のパッチ後）。
        final adapter = await MisskeyAdapter.create('misskey.example');
        adapter.client.dio.httpClientAdapter = _StaticAdapter(400, {
          'error': {
            'message': 'Access denied.',
            'code': 'ACCESS_DENIED',
            'id': '56f35758-7dd5-468b-8439-5d6fb8ec9b8e',
            'kind': 'client',
          },
        });

        expect(
          () => adapter.subscribePush(
            endpoint: 'https://relay.example/push/abc',
            p256dh: 'p256dh-dummy',
            auth: 'auth-dummy',
          ),
          throwsA(isA<PushRegistrationNotSupportedException>()),
        );
      },
    );

    test(
      '400 without ACCESS_DENIED also maps to PushRegistrationNotSupportedException',
      () async {
        // #365: /api/sw/register に対する 400 は内容に関係なくすべて非対応扱いに
        // 寄せる（Misskey フォークが別形状の 400 を返すケースを救うため）。
        final adapter = await MisskeyAdapter.create('misskey.example');
        adapter.client.dio.httpClientAdapter = _StaticAdapter(400, {
          'error': {'code': 'INVALID_PARAM', 'message': 'boom'},
        });

        expect(
          () => adapter.subscribePush(
            endpoint: 'https://relay.example/push/abc',
            p256dh: 'p256dh-dummy',
            auth: 'auth-dummy',
          ),
          throwsA(isA<PushRegistrationNotSupportedException>()),
        );
      },
    );

    test('404 (フォークが /api/sw/register を削除しているケース) も '
        'PushRegistrationNotSupportedException に寄せる', () async {
      // #365: モロヘイヤ非導入の Misskey フォークで /api/sw/register 自体が
      // 存在しない場合 (404) も同様に非対応扱い。
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _StaticAdapter(404, '');

      expect(
        () => adapter.subscribePush(
          endpoint: 'https://relay.example/push/abc',
          p256dh: 'p256dh-dummy',
          auth: 'auth-dummy',
        ),
        throwsA(isA<PushRegistrationNotSupportedException>()),
      );
    });

    test('403 (サーバーが push 登録を拒否するケース) も '
        'PushRegistrationNotSupportedException に寄せる', () async {
      // #705: misskey.io ほか非プリセットの公開サーバーが /api/sw/register を
      // 403 で拒否するケース（Sentry CAPSICUM-1T）。400 / 404 と同じ非対応扱い。
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _StaticAdapter(403, {
        'error': {'code': 'ACCESS_DENIED', 'message': 'Access denied.'},
      });

      expect(
        () => adapter.subscribePush(
          endpoint: 'https://relay.example/push/abc',
          p256dh: 'p256dh-dummy',
          auth: 'auth-dummy',
        ),
        throwsA(isA<PushRegistrationNotSupportedException>()),
      );
    });

    test('other status codes rethrow the DioException as-is', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _StaticAdapter(500, {
        'error': {'code': 'INTERNAL_ERROR'},
      });

      expect(
        () => adapter.subscribePush(
          endpoint: 'https://relay.example/push/abc',
          p256dh: 'p256dh-dummy',
          auth: 'auth-dummy',
        ),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('MisskeyAdapter.unsubscribePush (#1201)', () {
    test('鍵を渡すと auth / publickey が body に入る', () async {
      // Misskey 2026.10.0 の `paramDef` は endpoint / auth / publickey を
      // required にしており、endpoint 単体では
      // `INVALID_PARAM (must have required property 'auth')` の 400 になる。
      final adapter = await MisskeyAdapter.create('misskey.example');
      final capture = _CapturingAdapter();
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.unsubscribePush(
        endpoint: 'https://relay.example/push/abc',
        p256dh: 'p256dh-dummy',
        auth: 'auth-dummy',
      );

      expect(capture.lastPath, '/api/sw/unregister');
      final body = capture.lastData as Map<String, dynamic>;
      expect(body['endpoint'], 'https://relay.example/push/abc');
      // ⚠ Misskey 側のキー名は `publickey`（capsicum 内部は `p256dh`）。
      expect(body['publickey'], 'p256dh-dummy');
      expect(body['auth'], 'auth-dummy');
    });

    test('⚠ 鍵が null なら送らない（2026.10.0 より前のサーバーと同じ body）', () async {
      // 鍵が読めないインストール（v1.20 以前からのアップグレードで
      // PushKeyStore.read が null）では、従来どおり endpoint だけで試す。
      final adapter = await MisskeyAdapter.create('misskey.example');
      final capture = _CapturingAdapter();
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.unsubscribePush(endpoint: 'https://relay.example/push/abc');

      final body = capture.lastData as Map<String, dynamic>;
      expect(body['endpoint'], 'https://relay.example/push/abc');
      // ⚠⚠ **null を値として送ると、Ajv の `type: string` で 400 になる。**
      // キーごと落ちていることを見る（`containsPair(_, null)` では通る）。
      expect(body.containsKey('publickey'), isFalse);
      expect(body.containsKey('auth'), isFalse);
    });

    test('endpoint が null なら 1 本も投げない', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final capture = _CapturingAdapter();
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.unsubscribePush(p256dh: 'p256dh-dummy', auth: 'auth-dummy');

      expect(capture.lastPath, isNull);
    });
  });
}

/// 要求の path と body を控えるだけの adapter。
class _CapturingAdapter implements HttpClientAdapter {
  String? lastPath;
  Object? lastData;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastData = options.data;
    return ResponseBody.fromString(
      jsonEncode({}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
