import 'package:capsicum/src/ui/screen/login_attempts.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1112: ログイン試行が二重に走ったときの扱い。
///
/// ⚠ **原因は未特定のまま。**1 度しか観測できておらず logcat も残っていない。
/// ここで固定するのは「重なったときに何が起きるか」だけで、重なる原因を
/// 塞いだわけではない。⚠ **ガードを足して塞いだ、と読まないこと。**
///
/// ⚠⚠ **弾くのではなく前を畳んで新しい方を通す**のが要点。弾くと、画面が
/// 作り直されたあとユーザーがもう一度押しても何も起きない画面になる。
void main() {
  setUp(LoginAttempts.resetForTest);

  Future<void> noop() async {}
  final screenA = Object();
  final screenB = Object();

  Future<LoginTakeOver> take(
    int seq, {
    Object? owner,
    Future<void> Function()? teardown,
    DateTime? now,
  }) => LoginAttempts.takeOver(
    seq,
    owner: owner ?? screenA,
    teardown: teardown ?? noop,
    now: now,
  );

  test('番号はプロセス通しで増える（同じ操作で 2 回走ったのが番号で見える）', () {
    expect(LoginAttempts.nextSequence(), 1);
    expect(LoginAttempts.nextSequence(), 2);
    expect(LoginAttempts.nextSequence(), 3);
  });

  test('走っていなければ takeOver は「前の試行なし」を返す', () async {
    final result = await take(LoginAttempts.nextSequence());

    expect(result.overlap, isNull);
    expect(result.superseded, isFalse);
    expect(LoginAttempts.activeSequence, 1);
  });

  test('⚠ 重なったら前の番号を返し、前の後片づけを呼ぶ', () async {
    var tornDown = 0;
    await take(
      LoginAttempts.nextSequence(),
      teardown: () async {
        tornDown++;
      },
    );

    final result = await take(LoginAttempts.nextSequence());

    expect(result.overlap?.previousSequence, 1, reason: '重なりの記録に前の番号を載せる');
    expect(tornDown, 1, reason: 'ポート 7099 と keep-alive を先に畳む');
    expect(LoginAttempts.activeSequence, 2, reason: '新しい方が生きる');
  });

  test('⚠ 後片づけを待ってから戻る（ポート解放待ちを飛ばさない）', () async {
    var finished = false;
    await take(
      LoginAttempts.nextSequence(),
      teardown: () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        finished = true;
      },
    );

    await take(LoginAttempts.nextSequence());

    expect(finished, isTrue);
  });

  test('release で降りる', () async {
    final seq = LoginAttempts.nextSequence();
    await take(seq);

    LoginAttempts.release(seq);

    expect(LoginAttempts.activeSequence, isNull);
  });

  test('⚠⚠ 古い試行の release は新しい試行を消さない', () async {
    // `a4d86f64` の keep-alive 世代ガードと同じ理由。
    final first = LoginAttempts.nextSequence();
    await take(first);
    final second = LoginAttempts.nextSequence();
    await take(second);

    LoginAttempts.release(first);

    expect(LoginAttempts.activeSequence, second);
  });

  test('⚠ 降りたあとの試行は「重なった」と記録されない', () async {
    final first = LoginAttempts.nextSequence();
    await take(first);
    LoginAttempts.release(first);

    final result = await take(LoginAttempts.nextSequence());

    expect(result.overlap, isNull);
  });

  test('release は前の試行の後片づけを呼ばない（畳むのは takeOver の仕事）', () async {
    var tornDown = 0;
    final seq = LoginAttempts.nextSequence();
    await take(
      seq,
      teardown: () async {
        tornDown++;
      },
    );

    LoginAttempts.release(seq);

    expect(tornDown, 0);
  });

  group('#1144', () {
    test('⚠⚠ 3 本重なると、追い越された 2 本目は superseded を受け取る', () async {
      // Codex P2 / PR #1118。1 本目の後片づけを待っている間に 3 本目が来る。
      await take(
        LoginAttempts.nextSequence(),
        teardown: () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      final second = take(LoginAttempts.nextSequence());
      final third = await take(LoginAttempts.nextSequence());
      final secondResult = await second;

      expect(secondResult.superseded, isTrue, reason: '2 本目は降りる');
      expect(third.superseded, isFalse, reason: '最後に押したものが生きる');
      expect(LoginAttempts.activeSequence, 3);
    });

    test('isCurrent は資源を掴む直前の確認に使える', () async {
      final first = LoginAttempts.nextSequence();
      await take(first);
      expect(LoginAttempts.isCurrent(first), isTrue);

      await take(LoginAttempts.nextSequence());
      expect(LoginAttempts.isCurrent(first), isFalse);
    });

    test('⚠ 重なりの情報は定数ではない（同じ画面か・経過・最後のステップ）', () async {
      final t0 = DateTime.utc(2026, 9, 21, 12);
      final first = LoginAttempts.nextSequence();
      await take(first, owner: screenA, now: t0);
      LoginAttempts.markStep(first, 'oauth_server.listening');

      final sameScreen = await take(
        LoginAttempts.nextSequence(),
        owner: screenA,
        now: t0.add(const Duration(seconds: 30)),
      );
      expect(sameScreen.overlap!.sameOwner, isTrue);
      expect(sameScreen.overlap!.previousAge, const Duration(seconds: 30));
      expect(sameScreen.overlap!.previousStep, 'oauth_server.listening');
      expect(sameScreen.overlap!.isRapid, isFalse, reason: '良性の入り直し');

      final otherScreen = await take(
        LoginAttempts.nextSequence(),
        owner: screenB,
        now: t0.add(const Duration(seconds: 30, milliseconds: 300)),
      );
      expect(otherScreen.overlap!.sameOwner, isFalse, reason: '画面が作り直された');
      expect(otherScreen.overlap!.isRapid, isTrue, reason: '#1112 の本命の形');
    });

    test('⚠ 追い越された試行の markStep は新しい試行の記録を上書きしない', () async {
      final first = LoginAttempts.nextSequence();
      await take(first);
      final second = LoginAttempts.nextSequence();
      await take(second);
      LoginAttempts.markStep(second, 'login.start');
      LoginAttempts.markStep(first, 'oauth_server.listening');

      final third = await take(LoginAttempts.nextSequence());

      expect(third.overlap!.previousStep, 'login.start');
    });

    test('⚠ 前の後片づけが投げても、新しい試行は止まらない', () async {
      await take(
        LoginAttempts.nextSequence(),
        teardown: () async => throw StateError('boom'),
      );

      final result = await take(LoginAttempts.nextSequence());

      expect(result.superseded, isFalse);
      expect(LoginAttempts.activeSequence, 2);
    });
  });
}
