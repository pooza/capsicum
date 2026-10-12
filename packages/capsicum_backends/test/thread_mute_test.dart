import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1208: 会話（スレッド）のミュート。
///
/// 状態の出どころが SNS で違う —— Mastodon は投稿に `muted` が載り、Misskey は
/// Note に載らないので `notes/state` を別に引く。
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.routes);

  final Map<String, (int, Object)> routes;
  final List<String> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options.path);
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

Map<String, dynamic> _status(Map<String, dynamic> overrides) => {
  'id': '1',
  'created_at': '2026-09-11T00:00:00Z',
  'account': {
    'id': '1',
    'username': 'pooza',
    'acct': 'pooza',
    'display_name': 'pooza',
    'note': '',
    'avatar': '',
    'header': '',
    'followers_count': 0,
    'following_count': 0,
    'statuses_count': 0,
    'fields': <Map<String, dynamic>>[],
  },
  'content': '<p>ほげ</p>',
  'visibility': 'public',
  'favourites_count': 0,
  'reblogs_count': 0,
  'replies_count': 0,
  'media_attachments': <Map<String, dynamic>>[],
  ...overrides,
};

void main() {
  group('Mastodon: muted → Post.threadMuted', () {
    Post post(Map<String, dynamic> overrides) =>
        MastodonStatus.fromJson(_status(overrides)).toCapsicum('mstdn.example');

    test('ミュート中の会話の投稿は true', () {
      expect(post({'muted': true}).threadMuted, isTrue);
    });

    test('ミュートしていなければ false（項目の文面を出し分けられる）', () {
      expect(post({'muted': false}).threadMuted, isFalse);
    });

    test('⚠ 載っていなければ null（false と決めつけない）', () {
      // 未ログインで取った投稿などには載らない。
      expect(post({}).threadMuted, isNull);
    });
  });

  group('Misskey', () {
    test('ミュートすると、状態を載せた投稿が返る', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RoutingAdapter({
        'thread-muting/create': (204, ''),
        'notes/show': (200, _note),
        'notes/state': (200, {'isFavorited': true, 'isMutedThread': true}),
      });
      adapter.client.dio.httpClientAdapter = http;

      final post = await adapter.muteThread('note1');

      expect(post.threadMuted, isTrue);
      expect(
        post.bookmarked,
        isTrue,
        reason: '返した投稿は TL の行を置き換える。お気に入りの状態を false へ戻さない',
      );
      expect(http.calls.first, contains('thread-muting/create'));
    });

    test('⚠ 既にミュート中（ALREADY_MUTING）は成功と同じに倒す', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'thread-muting/create': (
          400,
          {
            'error': {
              'message': 'You are already muting that thread.',
              'code': 'ALREADY_MUTING',
              'id': 'c146e22d-1141-4b31-b28d-176371014d18',
            },
          },
        ),
        'notes/show': (200, _note),
        'notes/state': (200, {'isFavorited': false, 'isMutedThread': true}),
      });

      final post = await adapter.muteThread('note1');
      expect(post.threadMuted, isTrue);
    });

    test('⚠ それ以外の失敗（流量制限など）はそのまま投げる', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'thread-muting/create': (
          429,
          {
            'error': {'message': 'Rate limit.', 'code': 'RATE_LIMIT_EXCEEDED'},
          },
        ),
      });

      expect(() => adapter.muteThread('note1'), throwsA(isA<DioException>()));
    });

    test('解除すると false を載せて返る', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RoutingAdapter({
        'thread-muting/delete': (204, ''),
        'notes/show': (200, _note),
        'notes/state': (200, {'isFavorited': false, 'isMutedThread': false}),
      });
      adapter.client.dio.httpClientAdapter = http;

      final post = await adapter.unmuteThread('note1');

      expect(post.threadMuted, isFalse);
      expect(http.calls.first, contains('thread-muting/delete'));
    });

    test('いまの状態は notes/state の isMutedThread から読む', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'notes/state': (200, {'isFavorited': false, 'isMutedThread': true}),
      });
      expect(await adapter.isThreadMuted('note1'), isTrue);

      adapter.client.dio.httpClientAdapter = _RoutingAdapter({
        'notes/state': (200, {'isFavorited': true, 'isMutedThread': false}),
      });
      expect(
        await adapter.isThreadMuted('note1'),
        isFalse,
        reason: '⚠ お気に入りの旗（isFavorited）と取り違えない',
      );
    });
  });
}
