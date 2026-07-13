import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// パスごとに固定レスポンスを返し、直近リクエストの path/body を記録する
/// HttpClientAdapter。#174 の下書き CRUD をエンドポイント単位で検証する。
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.routes);

  final Map<String, (int, Object)> routes;
  final List<({String path, Map<String, dynamic> body})> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data;
    requests.add((
      path: options.path,
      body: data is Map<String, dynamic> ? data : <String, dynamic>{},
    ));
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

void main() {
  group('MisskeyAdapter drafts (#174)', () {
    test('getDrafts: NoteDraft を Draft にマップする（visibility→scope・添付）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _CapturingAdapter({
        'notes/drafts/list': (200, [
          {
            'id': 'd1',
            'createdAt': '2026-07-13T01:02:03.000Z',
            'text': 'こんにちは',
            'cw': '注意',
            'visibility': 'home',
            'files': [
              {
                'id': 'f1',
                'name': 'a.png',
                'type': 'image/png',
                'url': 'https://misskey.example/files/f1',
                'isSensitive': false,
              },
            ],
          },
        ]),
      });

      final drafts = await adapter.getDrafts();

      expect(drafts, hasLength(1));
      final d = drafts.first;
      expect(d.id, 'd1');
      expect(d.content, 'こんにちは');
      expect(d.spoilerText, '注意');
      // home は unlisted 相当。
      expect(d.scope, PostScope.unlisted);
      expect(d.attachments, hasLength(1));
      expect(d.attachments.first.id, 'f1');
      expect(d.createdAt.toUtc(), DateTime.utc(2026, 7, 13, 1, 2, 3));
    });

    test('getDrafts: list は scheduled:false で引く（予約投稿を除外）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final capture = _CapturingAdapter({
        'notes/drafts/list': (200, []),
      });
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.getDrafts();

      expect(capture.requests.single.body['scheduled'], isFalse);
    });

    test('saveDraft: scheduledAt / isActuallyScheduled を付けない（素の下書き）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final capture = _CapturingAdapter({
        'notes/drafts/create': (200, <String, dynamic>{}),
      });
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.saveDraft(
        const PostDraft(content: '下書きの本文', scope: PostScope.public),
      );

      final body = capture.requests.single.body;
      expect(body['text'], '下書きの本文');
      expect(body['visibility'], 'public');
      expect(body.containsKey('scheduledAt'), isFalse);
      expect(body.containsKey('isActuallyScheduled'), isFalse);
    });

    test('createScheduledNote は同じ drafts/create に scheduledAt 付きで載る', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final capture = _CapturingAdapter({
        'notes/drafts/create': (200, <String, dynamic>{}),
      });
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.client.createScheduledNote(
        text: '予約',
        visibility: 'public',
        scheduledAt: DateTime.utc(2026, 7, 14, 12),
      );

      final body = capture.requests.single.body;
      expect(body['isActuallyScheduled'], isTrue);
      expect(body['scheduledAt'], isNotNull);
    });

    test('deleteDraft: notes/drafts/delete に draftId を送る', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final capture = _CapturingAdapter({
        'notes/drafts/delete': (200, <String, dynamic>{}),
      });
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.deleteDraft('d9');

      final req = capture.requests.single;
      expect(req.path, contains('notes/drafts/delete'));
      expect(req.body['draftId'], 'd9');
    });
  });
}
