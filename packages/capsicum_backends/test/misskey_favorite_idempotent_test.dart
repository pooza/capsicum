import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// パスごとに固定レスポンスを返す HttpClientAdapter。
/// bookmarkPost は favorites/create に続けて notes/show を呼ぶため、
/// 2 つのエンドポイントを撃ち分ける必要がある。
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.routes);

  /// path 部分文字列 -> (statusCode, body)。
  final Map<String, (int, Object)> routes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final entry = routes.entries.firstWhere(
      (e) => options.path.contains(e.key),
      orElse: () => throw StateError('no route for ${options.path}'),
    );
    final (status, body) = entry.value;
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

const _note = <String, dynamic>{
  'id': 'note1',
  'createdAt': '2026-06-02T00:00:00.000Z',
  'userId': 'user1',
  'user': {'id': 'user1', 'username': 'alice'},
  'visibility': 'public',
  'renoteCount': 0,
  'repliesCount': 0,
};

void main() {
  group('MisskeyAdapter.bookmarkPost (#565)', () {
    test('ALREADY_FAVORITED の 400 は握りつぶして成功扱いにする', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'favorites/create': (
          400,
          {
            'error': {
              'message': 'Already favorited.',
              'code': 'ALREADY_FAVORITED',
              'id': 'a002a4a4-1c5e-4b3a-9b3a-000000000000',
            },
          },
        ),
        'notes/show': (200, _note),
      });

      final post = await adapter.bookmarkPost('note1');
      expect(post.id, 'note1');
    });

    test('ALREADY_FAVORITED 以外の 400 はそのまま投げる', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'favorites/create': (
          400,
          {
            'error': {
              'message': 'Rate limited.',
              'code': 'RATE_LIMIT_EXCEEDED',
            },
          },
        ),
        'notes/show': (200, _note),
      });

      expect(() => adapter.bookmarkPost('note1'), throwsA(isA<DioException>()));
    });
  });
}
