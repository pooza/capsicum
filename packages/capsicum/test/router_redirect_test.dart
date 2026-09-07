import 'package:capsicum/src/router.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1057: ログイン後の遷移を `LoginScreen` の生死に依存させない。
///
/// Android の OAuth は loopback callback（#276 / #654）なので、認可のあいだ
/// アプリはバックグラウンドに回り**キャッシュアプリ freezer に凍結される**。
/// 手動で戻すと解凍されてトークン交換が完走するが、その時点で `LoginScreen`
/// が生きているとは限らない。生きていないと `if (!mounted) return;` で黙って
/// 抜け、**アカウントだけ増えて画面はサーバー選択のまま**になっていた。
///
/// ⚠⚠ **「ログイン済みなら auth 画面から追い出す」では直せない。**設定から
/// 2 つ目のアカウントを足すときも `/server` を開くので、ログイン状態だけを見て
/// 飛ばすと**その導線が壊れる**。ここで固定するのは「壊していないこと」。
void main() {
  group('未ログイン', () {
    test('auth 画面はそのまま', () {
      for (final location in const ['/login', '/server', '/splash', '/eula']) {
        expect(
          resolveRedirect(
            isLoggedIn: false,
            location: location,
            justLoggedIn: false,
          ),
          isNull,
          reason: location,
        );
      }
    });

    test('それ以外はサーバー選択へ戻す', () {
      expect(
        resolveRedirect(
          isLoggedIn: false,
          location: '/home',
          justLoggedIn: false,
        ),
        '/server',
      );
    });
  });

  group('ログイン直後のフォールバック (#1057)', () {
    test('/server に居たらホームへ送る（LoginScreen が消えた場合）', () {
      expect(
        resolveRedirect(
          isLoggedIn: true,
          location: '/server',
          justLoggedIn: true,
        ),
        '/home',
      );
    });

    test('/login に居てもホームへ送る（画面は生きているが遷移が遅れた場合）', () {
      expect(
        resolveRedirect(
          isLoggedIn: true,
          location: '/login',
          justLoggedIn: true,
        ),
        '/home',
      );
    });

    test('splash と eula は飛ばさない', () {
      // splash は自分でルーティングを決める画面。eula は同意を取り切る前に
      // 飛ばしてはいけない。
      for (final location in const ['/splash', '/eula']) {
        expect(
          resolveRedirect(
            isLoggedIn: true,
            location: location,
            justLoggedIn: true,
          ),
          isNull,
          reason: location,
        );
      }
    });

    test('既にホームなら何もしない', () {
      expect(
        resolveRedirect(
          isLoggedIn: true,
          location: '/home',
          justLoggedIn: true,
        ),
        isNull,
      );
    });
  });

  group('⚠ 2 つ目のアカウントを足す導線を壊していない', () {
    test('ログイン済みでも /server はそのまま開ける', () {
      expect(
        resolveRedirect(
          isLoggedIn: true,
          location: '/server',
          justLoggedIn: false,
        ),
        isNull,
        reason:
            '設定 → アカウント追加は、ログイン済みのまま /server を開く。'
            'ログイン状態だけで飛ばすとこの導線が壊れる',
      );
    });

    test('ログイン済みでも /login はそのまま開ける', () {
      expect(
        resolveRedirect(
          isLoggedIn: true,
          location: '/login',
          justLoggedIn: false,
        ),
        isNull,
      );
    });
  });
}
