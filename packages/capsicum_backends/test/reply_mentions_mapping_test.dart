import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1161: 返信の宛先を組むために、Mastodon の `mentions` と Misskey の
/// `visibleUserIds` を Post へ通し、Misskey の指名は宛先を送る。
class _CapturingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data;
    bodies.add(data is Map<String, dynamic> ? data : <String, dynamic>{});
    final body = options.path.contains('notes/create')
        ? {
            'createdNote': {
              'id': 'n2',
              'createdAt': '2026-09-21T00:00:00.000Z',
              'userId': 'me',
              'user': {'id': 'me', 'username': 'pooza'},
              'text': 'x',
              'visibility': 'specified',
              'renoteCount': 0,
              'repliesCount': 0,
            },
          }
        : <String, dynamic>{};
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

void main() {
  MastodonStatus status(Map<String, dynamic> overrides) =>
      MastodonStatus.fromJson({
        'id': '1',
        'created_at': '2026-09-21T00:00:00Z',
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
      });

  MisskeyNote note(Map<String, dynamic> overrides) => MisskeyNote.fromJson({
    'id': 'n1',
    'createdAt': '2026-09-21T00:00:00.000Z',
    'userId': 'u1',
    'user': {'id': 'u1', 'username': 'admin'},
    'text': 'ほげ',
    'visibility': 'public',
    'renoteCount': 0,
    'repliesCount': 0,
    ...overrides,
  });

  group('Mastodon: mentions → Post.mentions', () {
    test('id と acct を順序どおり持つ', () {
      final post = status({
        'mentions': [
          {'id': '2', 'username': 'a', 'acct': 'a', 'url': ''},
          {'id': '3', 'username': 'b', 'acct': 'b@remote.example', 'url': ''},
        ],
      }).toCapsicum('mstdn.b-shock.org');

      expect(post.mentions.map((m) => (m.id, m.acct)), [
        ('2', 'a'),
        ('3', 'b@remote.example'),
      ]);
    });

    test('⚠ mentions が無い / 欠けた要素があっても落ちない', () {
      expect(status({}).toCapsicum('mstdn.b-shock.org').mentions, isEmpty);
      final post = status({
        'mentions': [
          {'id': '2'},
          {'id': '3', 'acct': 'c'},
        ],
      }).toCapsicum('mstdn.b-shock.org');
      expect(post.mentions.map((m) => m.acct), ['c']);
    });
  });

  group('Misskey: visibleUserIds → Post.visibleUserIds', () {
    test('指名ノートは宛先を持つ', () {
      final post = note({
        'visibility': 'specified',
        'visibleUserIds': ['a', 'b'],
      }).toCapsicum('misskey.example');
      expect(post.visibleUserIds, ['a', 'b']);
    });

    test('指名以外は空', () {
      expect(note({}).toCapsicum('misskey.example').visibleUserIds, isEmpty);
    });
  });

  group('Misskey: 指名の宛先を送る', () {
    Future<(MisskeyAdapter, _CapturingAdapter)> setUp() async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final capture = _CapturingAdapter();
      adapter.client.dio.httpClientAdapter = capture;
      return (adapter, capture);
    }

    const draft = PostDraft(
      content: '@a @b 返信',
      scope: PostScope.direct,
      inReplyToId: 'n1',
      // ⚠ サーバーは uniqueItems で弾くので、重複は落として送る。
      visibleUserIds: ['a', 'b', 'a'],
    );

    test('投稿', () async {
      final (adapter, capture) = await setUp();
      await adapter.postStatus(draft);
      expect(capture.bodies.single['visibility'], 'specified');
      expect(capture.bodies.single['visibleUserIds'], ['a', 'b']);
    });

    test('予約投稿', () async {
      final (adapter, capture) = await setUp();
      await adapter.postStatus(
        PostDraft(
          content: draft.content,
          scope: draft.scope,
          inReplyToId: draft.inReplyToId,
          visibleUserIds: draft.visibleUserIds,
          scheduledAt: DateTime.utc(2026, 9, 22),
        ),
      );
      expect(capture.bodies.single['visibleUserIds'], ['a', 'b']);
    });

    test('下書き', () async {
      final (adapter, capture) = await setUp();
      await adapter.saveDraft(draft);
      expect(capture.bodies.single['visibleUserIds'], ['a', 'b']);
    });

    test('宛先が空なら visibleUserIds を送らない', () async {
      final (adapter, capture) = await setUp();
      await adapter.postStatus(
        const PostDraft(content: 'x', scope: PostScope.followersOnly),
      );
      expect(capture.bodies.single.containsKey('visibleUserIds'), isFalse);
    });
  });
}
