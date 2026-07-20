import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// パスごとに固定レスポンスを返し、送信ボディを記録する HttpClientAdapter。
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.routes);

  /// path 部分文字列 -> (statusCode, body)。
  final Map<String, (int, Object)> routes;

  /// path 部分文字列 -> 実際に送られたリクエストボディ。
  final sentBodies = <String, Map<String, dynamic>>{};

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
    final data = options.data;
    sentBodies[entry.key] = data is Map<String, dynamic>
        ? data
        : jsonDecode(data as String) as Map<String, dynamic>;
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

const _flash = <String, dynamic>{
  'id': 'flash1',
  'createdAt': '2026-07-01T00:00:00.000Z',
  'updatedAt': '2026-07-02T00:00:00.000Z',
  'userId': 'user1',
  'user': {'id': 'user1', 'username': 'alice'},
  'title': 'ダイ大おみくじ',
  'summary': '今日の運勢',
  'script': '/// @ 1.2.0\nUi:render([])',
  'visibility': 'public',
  'likedCount': 3,
  'isLiked': true,
};

void main() {
  group('MisskeyAdapter Flash (#830)', () {
    test('featured を Flash にマップする', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'flash/featured': (200, [_flash]),
      });

      final flashes = await adapter.getFeaturedFlashes();

      expect(flashes, hasLength(1));
      final flash = flashes.single;
      expect(flash.id, 'flash1');
      expect(flash.title, 'ダイ大おみくじ');
      expect(flash.summary, '今日の運勢');
      expect(flash.script, contains('Ui:render'));
      expect(flash.author.username, 'alice');
      expect(flash.visibility, 'public');
      expect(flash.likedCount, 3);
      expect(flash.isLiked, isTrue);
      expect(flash.createdAt, DateTime.parse('2026-07-01T00:00:00.000Z'));
      expect(flash.updatedAt, DateTime.parse('2026-07-02T00:00:00.000Z'));
    });

    test('featured は sinceId ではなく limit だけを送る', () async {
      // このエンドポイントのページングは offset + limit で、sinceId /
      // untilId を受け付けない。誤って送らないことを固定する。
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RoutingAdapter({
        'flash/featured': (200, [_flash]),
      });
      adapter.client.dio.httpClientAdapter = http;

      await adapter.getFeaturedFlashes(
        query: const TimelineQuery(limit: 20, sinceId: 'x', maxId: 'y'),
      );

      final body = http.sentBodies['flash/featured']!;
      expect(body['limit'], 20);
      expect(body.containsKey('sinceId'), isFalse);
      expect(body.containsKey('untilId'), isFalse);
    });

    test('show は flashId パラメータで叩く', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RoutingAdapter({'flash/show': (200, _flash)});
      adapter.client.dio.httpClientAdapter = http;

      final flash = await adapter.getFlashById('flash1');

      expect(flash.id, 'flash1');
      expect(http.sentBodies['flash/show']!['flashId'], 'flash1');
    });

    test('updatedAt 欠落時は createdAt に倒す', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'flash/show': (200, {..._flash}..remove('updatedAt')),
      });

      final flash = await adapter.getFlashById('flash1');

      expect(flash.updatedAt, flash.createdAt);
    });

    test('script 欠落でも一覧表示は成立させる（空文字に倒す）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'flash/featured': (
          200,
          [
            {..._flash}..remove('script'),
          ],
        ),
      });

      final flashes = await adapter.getFeaturedFlashes();

      expect(flashes.single.script, isEmpty);
    });

    test('my-likes は likeId と flash を分離する', () async {
      // `id` はライクエントリ ID で Flash ID ではない。pagination cursor に
      // Flash ID を渡すと壊れるため、取り違えを固定する。
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'flash/my-likes': (
          200,
          [
            {'id': 'like1', 'flash': _flash},
          ],
        ),
      });

      final entries = await adapter.getLikedFlashes();

      expect(entries, hasLength(1));
      expect(entries.single.likeId, 'like1');
      expect(entries.single.flash.id, 'flash1');
    });

    test('my-likes の壊れたエントリは読み飛ばす', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'flash/my-likes': (
          200,
          [
            {'id': 'like1'}, // flash が無い
            {'flash': _flash}, // id が無い
            {'id': 'like2', 'flash': _flash},
          ],
        ),
      });

      final entries = await adapter.getLikedFlashes();

      expect(entries.map((e) => e.likeId), ['like2']);
    });

    test('like / unlike は flashId パラメータで叩く', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RoutingAdapter({
        'flash/like': (200, {}),
        'flash/unlike': (200, {}),
      });
      adapter.client.dio.httpClientAdapter = http;

      await adapter.likeFlash('flash1');
      await adapter.unlikeFlash('flash1');

      expect(http.sentBodies['flash/like']!['flashId'], 'flash1');
      expect(http.sentBodies['flash/unlike']!['flashId'], 'flash1');
    });
  });
}
