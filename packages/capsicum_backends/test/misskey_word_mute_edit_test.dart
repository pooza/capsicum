import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1290: Misskey のワードミュートを `i/update` で書き戻す。
void main() {
  Map<String, dynamic> note(String text) => {
    'id': 'n1',
    'createdAt': '2026-10-15T00:00:00.000Z',
    'userId': 'other',
    'user': {'id': 'other', 'username': 'someone'},
    'text': text,
    'visibility': 'public',
    'renoteCount': 0,
    'repliesCount': 0,
  };

  test('⚠ 保存は変えた段だけを送り、応答の語ですぐ判定し直す', () async {
    final stub = _RecordingAdapter(
      me: {'id': 'me', 'username': 'pooza', 'mutedWords': <Object>[]},
      notes: [note('ダイの大冒険は名作')],
    );
    final adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = stub;
    await adapter.getMyself();

    await adapter.setWordMutes(
      soft: const [
        ['ダイ'],
        '/大冒険/',
      ],
    );

    final body = stub.updates.single;
    expect(body['mutedWords'], [
      ['ダイ'],
      '/大冒険/',
    ]);
    expect(
      body.containsKey('hardMutedWords'),
      isFalse,
      reason: '変えていない段は送らない（全置換なので、送ると消える）',
    );

    // ⚠ getMyself を挟まずに、保存した語で判定されること。
    final post = (await adapter.getTimeline(TimelineType.home)).posts.single;
    expect(post.filterVerdictFor(null)?.action, FilterAction.warn);
  });

  test('getWordMutes はサーバーから取り直す（正規表現の行も読む）', () async {
    final stub = _RecordingAdapter(
      me: {
        'id': 'me',
        'username': 'pooza',
        'mutedWords': [
          ['ダイ', 'ポップ'],
          '/アバン/i',
        ],
        'hardMutedWords': ['/ハドラー/'],
      },
      notes: const [],
    );
    final adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = stub;

    final mutes = await adapter.getWordMutes();

    expect(mutes.soft, [
      ['ダイ', 'ポップ'],
      '/アバン/i',
    ]);
    expect(mutes.hard, ['/ハドラー/']);
  });

  // 2026-10-15 pooza 判断: 本家に揃えて区別する。
  test('⚠⚠ キーワードは大文字小文字を区別する（本家と同じ）', () async {
    final stub = _RecordingAdapter(
      me: {
        'id': 'me',
        'username': 'pooza',
        'mutedWords': [
          ['DAI'],
        ],
      },
      notes: [note('dai no daibouken')],
    );
    final adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = stub;
    await adapter.getMyself();

    final post = (await adapter.getTimeline(TimelineType.home)).posts.single;
    expect(post.filterVerdictFor(null), isNull);
  });
}

/// `/api/i`・`/api/i/update`・`/api/notes/timeline` を返し、`i/update` の本文を
/// 記録する。⚠ パスは完全一致で見る（`/api/i` が `/api/i/update` を飲まない）。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({required this.me, required this.notes});

  Map<String, dynamic> me;
  final List<Map<String, dynamic>> notes;
  final updates = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Object body;
    switch (options.path) {
      case '/api/i':
        body = me;
      case '/api/i/update':
        final data = Map<String, dynamic>.from(options.data as Map);
        updates.add(data);
        me = {
          ...me,
          if (data.containsKey('mutedWords')) 'mutedWords': data['mutedWords'],
          if (data.containsKey('hardMutedWords'))
            'hardMutedWords': data['hardMutedWords'],
        };
        body = me;
      case '/api/notes/timeline':
        body = notes;
      default:
        throw StateError('unexpected path ${options.path}');
    }
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
