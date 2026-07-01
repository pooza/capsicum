import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// MiAuth `/check` の応答を呼び出し毎に順番に返す HttpClientAdapter。
/// 各エントリは (statusCode, body) を返すか、DioException を投げる。
/// #276 のポーリング挙動（未承認→承認、一過性エラー→成功）を撃ち分ける。
class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.steps);

  /// 各呼び出しの応答。`(status, body)` を返すか、`DioException` を投げる。
  final List<Object> steps;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final step = steps[calls];
    calls++;
    if (step is DioException) {
      throw step;
    }
    final (status, body) = step as (int, Object);
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _approved = <String, dynamic>{
  'ok': true,
  'token': 'tok-123',
  'user': {'id': 'u1', 'username': 'alice'},
};

const _pending = <String, dynamic>{'ok': false};

Future<MisskeyAdapter> _adapter(List<Object> steps) async {
  final adapter = await MisskeyAdapter.create('misskey.example');
  adapter.miauthPollDelay = Duration.zero; // テストでは待たない
  adapter.client.dio.httpClientAdapter = _SequenceAdapter(steps);
  return adapter;
}

void main() {
  group('MisskeyAdapter.completeLogin MiAuth ポーリング (#276)', () {
    test('未承認(ok:false)が続いた後に承認されれば成功する', () async {
      final adapter = await _adapter([
        (200, _pending),
        (200, _pending),
        (200, _approved),
      ]);

      final result = await adapter.completeLogin(
        Uri.parse('http://localhost:7099/oauth/callback?session=s'),
        {'session': 's'},
      );

      expect(result, isA<LoginSuccess>());
      expect((result as LoginSuccess).userSecret.accessToken, 'tok-123');
    });

    test('一過性の connectionError の後に承認されれば成功する', () async {
      final adapter = await _adapter([
        DioException(
          requestOptions: RequestOptions(path: '/api/miauth/s/check'),
          type: DioExceptionType.connectionError,
        ),
        (200, _approved),
      ]);

      final result = await adapter.completeLogin(
        Uri.parse('http://localhost:7099/oauth/callback?session=s'),
        {'session': 's'},
      );

      expect(result, isA<LoginSuccess>());
    });

    test('最大試行まで未承認なら LoginFailure を返す', () async {
      final adapter = await _adapter(List<Object>.filled(3, (200, _pending)));
      adapter.miauthPollMaxAttempts = 3;

      final result = await adapter.completeLogin(
        Uri.parse('http://localhost:7099/oauth/callback?session=s'),
        {'session': 's'},
      );

      expect(result, isA<LoginFailure>());
    });

    test('恒久的な 4xx (badResponse) は再試行せず即失敗する', () async {
      final adapter = await _adapter([
        (400, {'error': 'bad'}),
        // 2 回目以降は呼ばれない想定（呼ばれたら範囲外アクセスで落ちる）。
      ]);

      final result = await adapter.completeLogin(
        Uri.parse('http://localhost:7099/oauth/callback?session=s'),
        {'session': 's'},
      );

      expect(result, isA<LoginFailure>());
      expect(
        (adapter.client.dio.httpClientAdapter as _SequenceAdapter).calls,
        1,
      );
    });
  });
}
