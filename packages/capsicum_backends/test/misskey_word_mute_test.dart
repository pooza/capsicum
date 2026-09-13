import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1117-B: Misskey のワードミュートが投稿の中身を落としていた。
///
/// ⚠⚠ **判定結果だけを載せるべきところで `Post(...)` を手で組み直していた**ため、
/// quote / poll / channel / localOnly / language などを軒並み捨てていた。warn が
/// 掛かった自分の投稿を「削除して再編集」すると、それらが落ちる形で表に出た。
///
/// ⚠⚠ **自分の投稿はそもそも対象外**（Misskey 本家の `check-word-mute.ts` が
/// backend / frontend の両方で `note.userId === me.id` を先頭で弾いている）。
void main() {
  Map<String, dynamic> note(Map<String, dynamic> overrides) => {
    'id': 'n1',
    'createdAt': '2026-09-13T00:00:00.000Z',
    'userId': 'other',
    'user': {'id': 'other', 'username': 'someone'},
    'text': 'ダイの大冒険は名作',
    'visibility': 'public',
    'renoteCount': 0,
    'repliesCount': 0,
    ...overrides,
  };

  /// `/api/i` と `/api/notes/timeline` だけを返す adapter。
  ///
  /// ⚠ **`getMyself` を通してからタイムラインを引く。**ミュート語と「自分が誰か」は
  /// どちらも `/api/i` で入るので、そこを省くと判定そのものが走らない。
  Future<MisskeyAdapter> adapterWith({
    required List<List<String>> mutedWords,
    required List<Map<String, dynamic>> notes,
    String myId = 'me',
  }) async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = _StubAdapter({
      '/api/i': {'id': myId, 'username': 'pooza', 'mutedWords': mutedWords},
      '/api/notes/timeline': notes,
    });
    await adapter.getMyself();
    return adapter;
  }

  Future<List<Post>> timelineOf(MisskeyAdapter adapter) async =>
      (await adapter.getTimeline(TimelineType.home)).posts;

  test('他人の投稿にミュート語があれば warn が載る', () async {
    final adapter = await adapterWith(
      mutedWords: [
        ['ダイの大冒険'],
      ],
      notes: [note({})],
    );

    final post = (await timelineOf(adapter)).single;

    expect(post.filterAction, FilterAction.warn);
    expect(post.filterTitle, 'ワードミュート');
  });

  // ⚠⚠ ここが本題。組み直しをやめないと軒並み落ちる。
  test('⚠⚠ warn が載っても投稿の中身を落とさない', () async {
    final adapter = await adapterWith(
      mutedWords: [
        ['ダイの大冒険'],
      ],
      notes: [
        note({
          'localOnly': true,
          'channel': {'id': 'ch1', 'name': '実況'},
          'poll': {
            'choices': [
              {'text': 'はい', 'votes': 1, 'isVoted': false},
              {'text': 'いいえ', 'votes': 0, 'isVoted': false},
            ],
            'multiple': false,
          },
          'cw': '注意',
          'renote': note({'id': 'n0', 'text': '引用元'}),
          'reactionAcceptance': 'likeOnly',
        }),
      ],
    );

    final post = (await timelineOf(adapter)).single;

    expect(post.filterAction, FilterAction.warn);
    expect(post.localOnly, isTrue, reason: '「ローカルのみ」が落ちると再編集で公開されうる');
    expect(post.channelId, 'ch1');
    expect(post.channelName, '実況');
    expect(post.poll, isNotNull);
    expect(post.quote, isNotNull, reason: '引用が落ちると再編集で引用が外れる');
    expect(post.spoilerText, '注意');
    expect(post.reactionAcceptance, ReactionAcceptance.likeOnly);
    expect(post.url, 'https://misskey.example/notes/n1');
  });

  test('⚠⚠ 自分の投稿はミュートしない（本家と同じ）', () async {
    final adapter = await adapterWith(
      mutedWords: [
        ['ダイの大冒険'],
      ],
      notes: [
        note({
          'userId': 'me',
          'user': {'id': 'me', 'username': 'pooza'},
        }),
      ],
    );

    final post = (await timelineOf(adapter)).single;

    expect(post.filterAction, isNull);
    expect(post.filterTitle, isNull);
  });

  test('ミュート語に当たらなければ何も載らない', () async {
    final adapter = await adapterWith(
      mutedWords: [
        ['アバン'],
      ],
      notes: [note({})],
    );

    expect((await timelineOf(adapter)).single.filterAction, isNull);
  });

  test('ミュート語が無ければ素通し', () async {
    final adapter = await adapterWith(mutedWords: [], notes: [note({})]);

    expect((await timelineOf(adapter)).single.filterAction, isNull);
  });

  // ⚠ AND 条件（配列の中の全語を含む）。本家と同じ扱い。
  test('複数語のグループは全部含むときだけ当たる', () async {
    final adapter = await adapterWith(
      mutedWords: [
        ['ダイ', 'ポップ'],
      ],
      notes: [
        note({}),
        note({'id': 'n2', 'text': 'ダイとポップ'}),
      ],
    );

    final posts = await timelineOf(adapter);

    expect(posts.firstWhere((p) => p.id == 'n1').filterAction, isNull);
    expect(
      posts.firstWhere((p) => p.id == 'n2').filterAction,
      FilterAction.warn,
    );
  });
}

/// パスごとに固定の JSON を返す最小 adapter。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.routes);

  final Map<String, Object> routes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final entry = routes.entries.firstWhere(
      (e) => options.path.contains(e.key),
      orElse: () => throw StateError('unexpected path ${options.path}'),
    );
    return ResponseBody.fromString(
      jsonEncode(entry.value),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
