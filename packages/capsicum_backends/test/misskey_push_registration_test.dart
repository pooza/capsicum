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
}
