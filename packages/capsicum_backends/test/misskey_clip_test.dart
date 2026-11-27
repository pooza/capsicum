import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1050: クリップの作成・編集・削除と、投稿の出し入れ。
///
/// path ごとに決めた応答（またはエラーコード）を返し、送られた本文を記録する。
class _Server implements HttpClientAdapter {
  _Server({this.errors = const {}, this.responses = const {}});

  /// path → Misskey のエラーコード。
  final Map<String, String> errors;

  /// path → 応答の本文。
  final Map<String, Object> responses;

  final calls = <String, Map<String, dynamic>>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;
    calls[path] = Map<String, dynamic>.from(options.data as Map);
    final code = errors[path];
    if (code != null) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'code': code},
        }),
        400,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(responses[path] ?? <String, dynamic>{}),
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
  late MisskeyAdapter adapter;

  Future<_Server> install(_Server server) async {
    adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = server;
    return server;
  }

  test('一覧は公開 / 非公開と作った人を読む', () async {
    await install(
      _Server(
        responses: {
          '/api/clips/list': [
            {
              'id': 'c1',
              'name': '実況',
              'description': 'あとで読む',
              'isPublic': true,
              'userId': 'me',
            },
            {'id': 'c2', 'name': '古い版'},
          ],
        },
      ),
    );

    final clips = await adapter.getClips();

    expect(clips.first.isPublic, isTrue);
    expect(clips.first.userId, 'me');
    expect(clips.last.isPublic, isFalse, reason: '欠けていたら非公開');
    expect(clips.last.userId, isNull);
  });

  group('作成・編集', () {
    test('作成は名前・説明・公開を送り、作ったクリップを返す', () async {
      final server = await install(
        _Server(
          responses: {
            '/api/clips/create': {'id': 'new', 'name': '実況', 'isPublic': true},
          },
        ),
      );

      final clip = await adapter.createClip(
        const ClipDraft(name: '実況', description: ' メモ ', isPublic: true),
      );

      expect(clip.id, 'new');
      final sent = server.calls['/api/clips/create']!;
      expect(sent['name'], '実況');
      expect(sent['description'], 'メモ');
      expect(sent['isPublic'], isTrue);
    });

    test('⚠ 説明が空なら null を送る（省くと編集で消せない）', () async {
      final server = await install(_Server());

      await adapter.updateClip('c1', const ClipDraft(name: '実況'));

      final sent = server.calls['/api/clips/update']!;
      expect(sent['clipId'], 'c1');
      expect(sent.containsKey('description'), isTrue);
      expect(sent['description'], isNull);
      expect(sent['isPublic'], isFalse);
    });

    test('上限（TOO_MANY_CLIPS）は ClipLimitReached', () async {
      await install(_Server(errors: {'/api/clips/create': 'TOO_MANY_CLIPS'}));

      expect(
        adapter.createClip(const ClipDraft(name: 'x')),
        throwsA(isA<ClipLimitReached>()),
      );
    });

    test('消えたクリップの編集（NO_SUCH_CLIP）は ClipNotFound', () async {
      await install(_Server(errors: {'/api/clips/update': 'NO_SUCH_CLIP'}));

      expect(
        adapter.updateClip('gone', const ClipDraft(name: 'x')),
        throwsA(isA<ClipNotFound>()),
      );
    });
  });

  group('削除', () {
    test('clipId を送る', () async {
      final server = await install(_Server());

      await adapter.deleteClip('c1');

      expect(server.calls['/api/clips/delete'], containsPair('clipId', 'c1'));
    });

    test('⚠ 既に消えていても成功として扱う', () async {
      await install(_Server(errors: {'/api/clips/delete': 'NO_SUCH_CLIP'}));

      await adapter.deleteClip('gone');
    });
  });

  group('投稿の出し入れ', () {
    test('入れる・外すは clipId と noteId を送る', () async {
      final server = await install(_Server());

      await adapter.addNoteToClip('c1', 'n1');
      await adapter.removeNoteFromClip('c1', 'n1');

      expect(server.calls['/api/clips/add-note'], {
        'clipId': 'c1',
        'noteId': 'n1',
      });
      expect(server.calls['/api/clips/remove-note'], {
        'clipId': 'c1',
        'noteId': 'n1',
      });
    });

    test('もう入っている（ALREADY_CLIPPED）は AlreadyClipped', () async {
      await install(
        _Server(errors: {'/api/clips/add-note': 'ALREADY_CLIPPED'}),
      );

      expect(adapter.addNoteToClip('c1', 'n1'), throwsA(isA<AlreadyClipped>()));
    });

    test('1 つのクリップの上限（TOO_MANY_CLIP_NOTES）は ClipNoteLimitReached', () async {
      await install(
        _Server(errors: {'/api/clips/add-note': 'TOO_MANY_CLIP_NOTES'}),
      );

      expect(
        adapter.addNoteToClip('c1', 'n1'),
        throwsA(isA<ClipNoteLimitReached>()),
      );
    });

    // #1379: 入れる投稿が消えていた / 外す投稿がもう外れていた。
    test('投稿が無い（NO_SUCH_NOTE）は入れる・外すとも ClipNoteNotFound', () async {
      await install(
        _Server(
          errors: {
            '/api/clips/add-note': 'NO_SUCH_NOTE',
            '/api/clips/remove-note': 'NO_SUCH_NOTE',
          },
        ),
      );

      expect(
        adapter.addNoteToClip('c1', 'n1'),
        throwsA(isA<ClipNoteNotFound>()),
      );
      expect(
        adapter.removeNoteFromClip('c1', 'n1'),
        throwsA(isA<ClipNoteNotFound>()),
      );
    });

    test('入っている公開クリップの id を返す（ほかの人のものも含む）', () async {
      final server = await install(
        _Server(
          responses: {
            '/api/notes/clips': [
              {'id': 'mine', 'name': 'a', 'userId': 'me'},
              {'id': 'theirs', 'name': 'b', 'userId': 'other'},
            ],
          },
        ),
      );

      final ids = await adapter.getPublicClipIdsContaining('n1');

      expect(ids, {'mine', 'theirs'});
      expect(server.calls['/api/notes/clips'], containsPair('noteId', 'n1'));
    });
  });

  // #1377: ほかの人のクリップを見る・お気に入りに入れる。
  group('ほかの人のクリップ', () {
    test('users/clips は userId を送り、持ち主の名前とお気に入りの状態を読む', () async {
      final server = await install(
        _Server(
          responses: {
            '/api/users/clips': [
              {
                'id': 'c1',
                'name': '名場面',
                'userId': 'u1',
                'isPublic': true,
                'isFavorited': true,
                'user': {'username': 'alice', 'name': 'アリス'},
              },
              {
                'id': 'c2',
                'name': '名前の無い人',
                'user': {'username': 'bob', 'name': ''},
              },
            ],
          },
        ),
      );

      final clips = await adapter.getUserClips(
        'u1',
        query: const TimelineQuery(limit: 20, maxId: 'c0'),
      );

      expect(server.calls['/api/users/clips'], containsPair('userId', 'u1'));
      expect(server.calls['/api/users/clips'], containsPair('untilId', 'c0'));
      expect(clips.first.ownerName, 'アリス');
      expect(clips.first.isFavorited, isTrue);
      expect(clips.last.ownerName, 'bob', reason: '表示名が空なら username');
      expect(clips.last.isFavorited, isNull, reason: '分からなければ null');
    });

    test('お気に入りに入れる・外すは clipId を送る', () async {
      final server = await install(_Server());

      await adapter.favoriteClip('c1');
      await adapter.unfavoriteClip('c1');

      expect(server.calls['/api/clips/favorite'], containsPair('clipId', 'c1'));
      expect(
        server.calls['/api/clips/unfavorite'],
        containsPair('clipId', 'c1'),
      );
    });

    test('⚠ 既に入っていた / もう外れていたは成功として扱う', () async {
      await install(
        _Server(
          errors: {
            '/api/clips/favorite': 'ALREADY_FAVORITED',
            '/api/clips/unfavorite': 'NOT_FAVORITED',
          },
        ),
      );

      await adapter.favoriteClip('c1');
      await adapter.unfavoriteClip('c1');
    });

    test('消えたクリップ（NO_SUCH_CLIP）は ClipNotFound', () async {
      await install(
        _Server(
          errors: {
            '/api/clips/favorite': 'NO_SUCH_CLIP',
            '/api/clips/show': 'NO_SUCH_CLIP',
          },
        ),
      );

      expect(adapter.favoriteClip('gone'), throwsA(isA<ClipNotFound>()));
      expect(adapter.getClip('gone'), throwsA(isA<ClipNotFound>()));
    });

    test('お気に入りの一覧を引く', () async {
      await install(
        _Server(
          responses: {
            '/api/clips/my-favorites': [
              {'id': 'c9', 'name': 'お気に入り', 'userId': 'u2'},
            ],
          },
        ),
      );

      final clips = await adapter.getFavoriteClips();

      expect(clips.single.id, 'c9');
    });
  });
}
