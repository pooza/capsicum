import 'package:capsicum/src/router.dart';
import 'package:flutter_test/flutter_test.dart';

/// 認証ゲートの判定（副作用なし）。
///
/// ⚠⚠ **ここでログイン直後の引き上げをやらない (#1057)。**`location` は
/// `matchList.uri.path` で、**`push` で積んだぶんは反映されない**。ホームから
/// 「アカウントを追加」→ `/server` → `/login` と積んでも `/home` のままになる
/// ので、「今どの画面に居るか」では判断できない。実機で 1 度これを踏んだ
/// （旗は消費されたのに引き上げが起きなかった）。ログイン直後の遷移は
/// `routerProvider` の listener が持ち、その前提は `router_login_args_test`
/// で固定してある。
///
/// ⚠ **「ログイン済みなら auth 画面から追い出す」とも書かない。**設定から
/// 2 つ目のアカウントを足すときも `/server` を開くので、ログイン状態だけを見て
/// 飛ばすと**その導線が壊れる**。ここで固定するのは「壊していないこと」。
void main() {
  group('未ログイン', () {
    test('auth 画面はそのまま', () {
      for (final location in const ['/login', '/server', '/splash', '/eula']) {
        expect(
          resolveRedirect(isLoggedIn: false, location: location),
          isNull,
          reason: location,
        );
      }
    });

    test('それ以外はサーバー選択へ戻す', () {
      expect(resolveRedirect(isLoggedIn: false, location: '/home'), '/server');
    });
  });

  group('⚠ 2 つ目のアカウントを足す導線を壊していない', () {
    test('ログイン済みでも /server はそのまま開ける', () {
      expect(
        resolveRedirect(isLoggedIn: true, location: '/server'),
        isNull,
        reason:
            '設定 → アカウント追加は、ログイン済みのまま /server を開く。'
            'ログイン状態だけで飛ばすとこの導線が壊れる',
      );
    });

    test('ログイン済みでも /login はそのまま開ける', () {
      expect(resolveRedirect(isLoggedIn: true, location: '/login'), isNull);
    });

    test('ログイン済みなら通常の画面もそのまま', () {
      for (final location in const ['/home', '/settings', '/compose']) {
        expect(
          resolveRedirect(isLoggedIn: true, location: location),
          isNull,
          reason: location,
        );
      }
    });
  });
}
