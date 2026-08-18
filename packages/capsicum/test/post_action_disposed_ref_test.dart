import 'package:capsicum/src/ui/util/post_actions.dart';
import 'package:capsicum/src/ui/util/visible_timeline.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #990 の回帰テスト（Sentry CAPSICUM-4N）。
///
/// **眼目は「画面へ反映できない」を「操作そのものを捨てる」に昇格させないこと。**
///
/// リアクションはボトムシートで絵文字を選んでもらう形で、`onSelected` はシートを
/// pop した**後**に走る。その間に背後の TL が更新されて `PostTile` の element が
/// 破棄されていると、`readVisibleTimelines(ref)` が StateError を投げていた。
/// しかもその呼び出しは `runReaction` の 1 行目＝`action()` より**前**にあったため:
///
/// - `addReaction` が一度も呼ばれない（サーバーへ届かない）
/// - `_report` にも入らないので `phase` の失敗計装に乗らない
/// - スナックバーも出ないので、ユーザーには成功も失敗も見えない
///
/// つまり**リアクションが無言で消えていた**。
void main() {
  testWidgets('dispose 済みの ref でもリアクションが送信される (#990)', (tester) async {
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

    // シートが開いている間にタイルが消えた状況を作る。
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      ),
    );

    // 前提の確認: この ref を直に触ると投げる（＝再現条件が成立している）。
    expect(
      () => readVisibleTimelines(captured),
      throwsA(isA<StateError>()),
      reason: 'dispose されていないなら、このテストは何も検証していない',
    );

    var actionCalled = false;
    await PostActionRunner(ref: captured, messenger: messenger).runReaction(
      _ThrowingAdapter(),
      'post-1',
      () async {
        actionCalled = true;
      },
      'リアクションしました',
    );

    expect(actionCalled, isTrue, reason: '反映先が取れないだけで、リアクション自体は送信されなければならない');
  });

  test('detached は反映先を持たず、どの操作も投げない (#990)', () {
    const mutator = VisibleTimelineMutator.detached;
    expect(() => mutator.removePost('x'), returnsNormally);
    expect(() => mutator.updatePost(_dummyPost), returnsNormally);
    expect(() => mutator.insertOwnPost(_dummyPost), returnsNormally);
  });
}

final _dummyPost = Post(
  id: 'post-1',
  postedAt: DateTime.utc(2026, 8, 18),
  author: const User(id: 'u1', username: 'me'),
  content: 'body',
);

/// `getPostById` まで到達したかは問わない（到達＝`action()` は呼ばれている）。
/// 投げても `runReaction` の catch が受けるので、テストの主張には影響しない。
class _ThrowingAdapter implements BackendAdapter {
  @override
  Future<Post> getPostById(String id) async => throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
