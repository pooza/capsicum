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

      await adapter.getFeaturedFlashes();

      final body = http.sentBodies['flash/featured']!;
      // ⚠ 既定は 10 件。offset 方式で 1 回に取れる上限（100）を明示する。
      expect(body['limit'], 100);
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

    test('MiAuth スコープに flash-likes 系を含む（いいねが 403 にならない）', () async {
      // これが欠けると flash/like・flash/unlike が write:flash-likes 不足で 403
      // になり、Play のいいねが全ユーザーで機能不全になる（リリース前レビューで
      // 検出・page-likes と同型）。startLogin が組み立てる permission を固定する。
      final adapter = await MisskeyAdapter.create('misskey.example');
      final result = await adapter.startLogin(
        ApplicationInfo(
          name: 'capsicum',
          redirectUri: Uri.parse('http://localhost:7099/oauth/callback'),
        ),
      );

      expect(result, isA<LoginNeedsOAuth>());
      final perms = (result as LoginNeedsOAuth)
          .authorizationUrl
          .queryParameters['permission']!
          .split(',');
      expect(perms, contains('write:flash-likes'));
      expect(perms, contains('read:flash-likes'));
      expect(perms, contains('read:flash'));
      expect(perms, contains('write:flash'));
    });

    // #1351: 検索の既定は 5 件。
    test('search は query と limit を送る（最初のページは起点なし）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RoutingAdapter({
        'flash/search': (200, [_flash]),
      });
      adapter.client.dio.httpClientAdapter = http;

      final found = await adapter.searchFlashes('おみくじ');

      expect(found.single.id, 'flash1');
      final body = http.sentBodies['flash/search'];
      expect(body, containsPair('query', 'おみくじ'));
      expect(body, containsPair('limit', 100));
      expect(body!.containsKey('untilId'), isFalse);
    });

    test('delete は flashId を送る', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RoutingAdapter({'flash/delete': (200, '')});
      adapter.client.dio.httpClientAdapter = http;

      await adapter.deleteFlash('flash1');

      expect(
        http.sentBodies['flash/delete'],
        containsPair('flashId', 'flash1'),
      );
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

      final flashes = await adapter.getLikedFlashes();

      expect(flashes.single.id, 'flash1');
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

      final flashes = await adapter.getLikedFlashes();

      expect(flashes, hasLength(1));
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

  // #1361: ページ送りはアダプターが持つ（チャンネルと同じ層）。
  group('ページ送り', () {
    test('⚠ いいねの次のページは、いいねの ID を起点にする（Flash の ID ではない）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _PagingAdapter(
        firstPage: [
          for (var i = 0; i < 100; i++)
            {
              'id': 'like$i',
              'flash': {..._flash, 'id': 'f$i'},
            },
        ],
      );
      adapter.client.dio.httpClientAdapter = http;

      final flashes = await adapter.getLikedFlashes();

      expect(http.untilIds, [null, 'like99']);
      expect(flashes, hasLength(100));
      expect(flashes.last.id, 'f99');
    });

    test('自分の Play は Flash の ID を起点にし、満たないページで止める', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _PagingAdapter(
        firstPage: [
          for (var i = 0; i < 100; i++) {..._flash, 'id': 'm$i'},
        ],
      );
      adapter.client.dio.httpClientAdapter = http;

      await adapter.getMyFlashes();

      expect(http.untilIds, [null, 'm99']);
    });

    test('⚠ 上限（10 ページ）で止める（広い語の検索で叩き続けない）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _PagingAdapter(
        firstPage: [
          for (var i = 0; i < 100; i++) {..._flash, 'id': 's$i'},
        ],
        repeat: true,
      );
      adapter.client.dio.httpClientAdapter = http;

      await adapter.searchFlashes('a');

      expect(http.untilIds, hasLength(10));
    });
  });
}

/// 最初のページに [firstPage] を返し、次からは空（[repeat] なら同じもの）を返す。
/// 送られた `untilId` を順に記録する。
class _PagingAdapter implements HttpClientAdapter {
  _PagingAdapter({required this.firstPage, this.repeat = false});

  final List<Map<String, dynamic>> firstPage;
  final bool repeat;
  final untilIds = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data as Map<String, dynamic>;
    final untilId = data['untilId'] as String?;
    untilIds.add(untilId);
    final body = untilId == null || repeat ? firstPage : <Object>[];
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
