import 'package:capsicum/src/ui/util/post_actions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1208: 会話（スレッド）のミュートの出し方（2026-10-12 pooza）。
///
/// - 出すのは自分の投稿と自分宛ての投稿（通知のシートは常に出す）
/// - Mastodon は状態が投稿に載るので「ミュート」「解除」を出し分ける
/// - Misskey は載らないので 1 項目にし、押した時点で状態を引く
const _me = User(id: 'me', username: 'pooza');

Post _post({
  String authorId = 'other',
  String? content,
  bool isHtml = false,
  bool? threadMuted,
  List<PostMention> mentions = const [],
  List<String> visibleUserIds = const [],
}) => Post(
  id: 'p1',
  postedAt: DateTime.utc(2026, 10, 12),
  author: User(id: authorId, username: 'someone'),
  content: content,
  isHtml: isHtml,
  threadMuted: threadMuted,
  mentions: mentions,
  visibleUserIds: visibleUserIds,
);

class _Adapter implements ThreadMuteSupport {
  _Adapter({this.muted = false, this.failState = false});

  bool muted;
  final bool failState;
  final List<String> calls = [];

  @override
  Future<bool> isThreadMuted(String postId) async {
    calls.add('state');
    if (failState) throw Exception('boom');
    return muted;
  }

  @override
  Future<Post> muteThread(String postId) async {
    calls.add('mute');
    muted = true;
    return _post(threadMuted: true);
  }

  @override
  Future<Post> unmuteThread(String postId) async {
    calls.add('unmute');
    muted = false;
    return _post(threadMuted: false);
  }
}

void main() {
  group('項目の文面', () {
    test('状態が分かっていれば出し分ける（Mastodon）', () {
      expect(threadMuteLabel(_post(threadMuted: false)), '会話をミュート');
      expect(threadMuteLabel(_post(threadMuted: true)), '会話のミュートを解除');
    });

    test('⚠ 分からないときは「…」を付ける（押すと状態を引く・Misskey）', () {
      expect(threadMuteLabel(_post()), '会話をミュート…');
    });
  });

  group('出す投稿', () {
    test('自分の投稿には出す', () {
      expect(threadMuteApplies(_post(authorId: 'me'), _me), isTrue);
    });

    test('⚠ 関わっていない他人の投稿には出さない（シートを伸ばさない）', () {
      expect(threadMuteApplies(_post(content: 'こんにちは'), _me), isFalse);
      expect(
        threadMuteApplies(_post(content: '<p>こんにちは</p>', isHtml: true), _me),
        isFalse,
      );
    });

    test('Mastodon: 宛先のメンションに自分が居れば出す', () {
      final post = _post(
        content: '<p>@pooza どうも</p>',
        isHtml: true,
        mentions: const [PostMention(id: 'me', acct: 'pooza')],
      );
      expect(threadMuteApplies(post, _me), isTrue);
    });

    test('Misskey: 本文に自分へのメンションがあれば出す', () {
      expect(threadMuteApplies(_post(content: '@pooza どうも'), _me), isTrue);
      expect(threadMuteApplies(_post(content: 'どうも @Pooza'), _me), isTrue);
      expect(
        threadMuteApplies(_post(content: '@pooza@misskey.example へ'), _me),
        isTrue,
      );
    });

    test('⚠ Misskey: 別のユーザー名の一部に当てない', () {
      expect(threadMuteApplies(_post(content: '@pooza2 どうも'), _me), isFalse);
      expect(
        threadMuteApplies(_post(content: 'a@pooza.example'), _me),
        isFalse,
      );
    });

    test('Misskey: 指名の宛先に自分が居れば出す', () {
      expect(
        threadMuteApplies(_post(visibleUserIds: const ['me']), _me),
        isTrue,
      );
    });

    test('ログインしていなければ出さない', () {
      expect(threadMuteApplies(_post(authorId: 'me'), null), isFalse);
    });
  });

  group('切り替え', () {
    Future<(PostActionRunner, List<Post>)> runner(WidgetTester tester) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  captured = ref;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      final messenger = tester.state<ScaffoldMessengerState>(
        find.byType(ScaffoldMessenger),
      );
      final updated = <Post>[];
      return (
        PostActionRunner(
          ref: captured,
          messenger: messenger,
          onPostUpdated: updated.add,
        ),
        updated,
      );
    }

    testWidgets('Mastodon: 未ミュートと分かっていれば、状態を引かずにミュートする', (tester) async {
      final (r, updated) = await runner(tester);
      final adapter = _Adapter();

      await r.toggleThreadMute(
        adapter: adapter,
        post: _post(threadMuted: false),
        confirmUnmute: () async => fail('確認は出さない'),
      );
      await tester.pump();

      expect(adapter.calls, ['mute']);
      expect(updated.single.threadMuted, isTrue);
      expect(find.textContaining('会話をミュートしました'), findsOneWidget);
    });

    testWidgets('Mastodon: ミュート中と分かっていれば、確認なしで解除する', (tester) async {
      // 項目の文面が「会話のミュートを解除」になっているので、確かめ直さない。
      final (r, updated) = await runner(tester);
      final adapter = _Adapter(muted: true);

      await r.toggleThreadMute(
        adapter: adapter,
        post: _post(threadMuted: true),
        confirmUnmute: () async => fail('確認は出さない'),
      );
      await tester.pump();

      expect(adapter.calls, ['unmute']);
      expect(updated.single.threadMuted, isFalse);
      expect(find.text('会話のミュートを解除しました'), findsOneWidget);
    });

    testWidgets('Misskey: 状態を引き、未ミュートならそのままミュートする', (tester) async {
      final (r, _) = await runner(tester);
      final adapter = _Adapter();

      await r.toggleThreadMute(
        adapter: adapter,
        post: _post(),
        confirmUnmute: () async => fail('未ミュートなら確認は出さない'),
      );

      expect(adapter.calls, ['state', 'mute']);
    });

    testWidgets('⚠⚠ Misskey: ミュート中なら確かめてから解除する（黙って解除しない）', (tester) async {
      final (r, _) = await runner(tester);
      final adapter = _Adapter(muted: true);
      var asked = 0;

      await r.toggleThreadMute(
        adapter: adapter,
        post: _post(),
        confirmUnmute: () async {
          asked++;
          return false;
        },
      );

      expect(asked, 1);
      expect(adapter.calls, ['state'], reason: '断ったら何も送らない');
      expect(adapter.muted, isTrue);

      await r.toggleThreadMute(
        adapter: adapter,
        post: _post(),
        confirmUnmute: () async => true,
      );
      expect(adapter.calls, ['state', 'state', 'unmute']);
    });

    // #1283: 状態を引いている間に、押したタイルが破棄された回。
    testWidgets('⚠ Misskey: 確かめられなかったら解除せず、既にミュートしていると知らせる', (tester) async {
      final (r, updated) = await runner(tester);
      final adapter = _Adapter(muted: true);

      await r.toggleThreadMute(
        adapter: adapter,
        post: _post(),
        confirmUnmute: () async => null,
      );
      await tester.pump();

      expect(adapter.calls, ['state'], reason: '解除しない側に倒す');
      expect(adapter.muted, isTrue);
      expect(updated, isEmpty);
      expect(find.text('この会話は既にミュートしています'), findsOneWidget);
    });

    testWidgets('Misskey: キャンセルした回は、何も出さない', (tester) async {
      final (r, _) = await runner(tester);
      final adapter = _Adapter(muted: true);

      await r.toggleThreadMute(
        adapter: adapter,
        post: _post(),
        confirmUnmute: () async => false,
      );
      await tester.pump();

      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('⚠ 破棄されたタイルからは確かめられない（null を返す）', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());

      expect(await confirmThreadUnmute(captured), isNull);
    });

    testWidgets('⚠ 状態が引けなかったら、ミュートも解除もしない', (tester) async {
      final (r, updated) = await runner(tester);
      final adapter = _Adapter(failState: true);

      await r.toggleThreadMute(
        adapter: adapter,
        post: _post(),
        confirmUnmute: () async => true,
      );
      await tester.pump();

      expect(adapter.calls, ['state']);
      expect(updated, isEmpty);
    });
  });
}
