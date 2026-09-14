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

  test('番号はプロセス通しで増える（同じ操作で 2 回走ったのが番号で見える）', () {
    expect(LoginAttempts.nextSequence(), 1);
    expect(LoginAttempts.nextSequence(), 2);
    expect(LoginAttempts.nextSequence(), 3);
  });

  test('走っていなければ takeOver は「前の試行なし」を返す', () async {
    final previous = await LoginAttempts.takeOver(
      LoginAttempts.nextSequence(),
      noop,
    );

    expect(previous, isNull);
    expect(LoginAttempts.activeSequence, 1);
  });

  test('⚠ 重なったら前の番号を返し、前の後片づけを呼ぶ', () async {
    var tornDown = 0;
    await LoginAttempts.takeOver(LoginAttempts.nextSequence(), () async {
      tornDown++;
    });

    final previous = await LoginAttempts.takeOver(
      LoginAttempts.nextSequence(),
      noop,
    );

    expect(previous, 1, reason: '重なりの記録に前の試行番号を載せるため');
    expect(tornDown, 1, reason: 'ポート 7099 と keep-alive を先に畳む');
    expect(LoginAttempts.activeSequence, 2, reason: '新しい方が生きる');
  });

  test('⚠ 後片づけを待ってから差し替える（ポート解放待ちを飛ばさない）', () async {
    var finished = false;
    await LoginAttempts.takeOver(LoginAttempts.nextSequence(), () async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      finished = true;
    });

    await LoginAttempts.takeOver(LoginAttempts.nextSequence(), noop);

    expect(finished, isTrue);
  });

  test('release で降りる', () async {
    final seq = LoginAttempts.nextSequence();
    await LoginAttempts.takeOver(seq, noop);

    LoginAttempts.release(seq);

    expect(LoginAttempts.activeSequence, isNull);
  });

  test('⚠⚠ 古い試行の release は新しい試行を消さない', () async {
    // `a4d86f64` の keep-alive 世代ガードと同じ理由。1 本目の finally が
    // 2 本目を消すと、生きている試行が登録簿から消えて後片づけが迷子になる。
    final first = LoginAttempts.nextSequence();
    await LoginAttempts.takeOver(first, noop);
    final second = LoginAttempts.nextSequence();
    await LoginAttempts.takeOver(second, noop);

    LoginAttempts.release(first);

    expect(LoginAttempts.activeSequence, second);
  });

  test('⚠ 降りたあとの試行は「重なった」と記録されない', () async {
    final first = LoginAttempts.nextSequence();
    await LoginAttempts.takeOver(first, noop);
    LoginAttempts.release(first);

    final previous = await LoginAttempts.takeOver(
      LoginAttempts.nextSequence(),
      noop,
    );

    expect(previous, isNull);
  });

  test('release は前の試行の後片づけを呼ばない（畳むのは takeOver の仕事）', () async {
    var tornDown = 0;
    final seq = LoginAttempts.nextSequence();
    await LoginAttempts.takeOver(seq, () async {
      tornDown++;
    });

    LoginAttempts.release(seq);

    // 自分の資源は自分の finally が閉じる。登録簿は次の試行のためだけに持つ。
    expect(tornDown, 0);
  });
}
