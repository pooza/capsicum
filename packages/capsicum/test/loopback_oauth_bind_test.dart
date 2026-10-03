import 'dart:io';

import 'package:capsicum/src/platform/loopback_oauth_bind.dart';
import 'package:flutter_test/flutter_test.dart';

/// #813 loopback OAuth サーバの bind リトライ。前回試行の残存リスナ等による
/// 一時的な EADDRINUSE を吸収し、使い切ったら LoopbackPortOccupiedException を
/// 投げることを実ソケットで検証する。
void main() {
  group('bindLoopbackOAuthServer', () {
    test('空きポートには bind できサーバを返す', () async {
      // エフェメラルポートを 1 つ確保→即解放して「空き」ポート番号を得る。
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      final server = await bindLoopbackOAuthServer(port);
      addTearDown(() => server.close(force: true));
      expect(server.port, port);
    });

    test('占有され続けるポートは使い切って LoopbackPortOccupiedException', () async {
      final occupier = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => occupier.close());
      final port = occupier.port;

      var sleeps = 0;
      await expectLater(
        bindLoopbackOAuthServer(
          port,
          maxAttempts: 3,
          sleep: (_) async => sleeps++,
        ),
        throwsA(
          isA<LoopbackPortOccupiedException>().having(
            (e) => e.port,
            'port',
            port,
          ),
        ),
      );
      // 3 回試行 = 試行間の sleep は 2 回。
      expect(sleeps, 2);
    });

    test('バックオフ中に解放されればリトライで成功する', () async {
      final occupier = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = occupier.port;
      var closed = false;

      final server = await bindLoopbackOAuthServer(
        port,
        maxAttempts: 3,
        // 最初の sleep（= 2 回目の bind の前）でポートを解放する。
        sleep: (_) async {
          if (!closed) {
            closed = true;
            await occupier.close();
          }
        },
      );
      addTearDown(() => server.close(force: true));
      expect(server.port, port);
    });

    test('既定のリトライ窓は 6 回（sleep 5 回）に広げてある (#859)', () async {
      // #813 当初の 3 回では解放遅れを吸収しきれない端末があったため、既定を
      // 6 回へ拡張した。占有され続けるポートで既定の試行回数を実測する。
      final occupier = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => occupier.close());
      final port = occupier.port;

      var sleeps = 0;
      await expectLater(
        // maxAttempts を明示せず既定に委ねる。
        bindLoopbackOAuthServer(port, sleep: (_) async => sleeps++),
        throwsA(isA<LoopbackPortOccupiedException>()),
      );
      // 6 回試行 = 試行間の sleep は 5 回。
      expect(sleeps, 5);
    });

    test('maxAttempts=1 は sleep せず即失敗', () async {
      final occupier = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => occupier.close());
      final port = occupier.port;

      var sleeps = 0;
      await expectLater(
        bindLoopbackOAuthServer(
          port,
          maxAttempts: 1,
          sleep: (_) async => sleeps++,
        ),
        throwsA(isA<LoopbackPortOccupiedException>()),
      );
      expect(sleeps, 0);
    });
  });

  /// #1140: ブラウザが「前回のセッションを復元」すると、前回ログインしたときの
  /// callback タブが承認より先に届く。⚠⚠ **それを受け取ってはいけない**（受け
  /// 取って閉じると、今回の試行は照合に落ち、本物は「接続が拒否されました」）。
  group('isExpectedOAuthCallback (#790 / #1140)', () {
    const path = '/oauth/callback';
    Uri cb(String query) => Uri.parse('http://localhost:7099$path?$query');

    test('Mastodon: 今回の state なら受け取る（error 応答も）', () {
      expect(
        isExpectedOAuthCallback(
          cb('code=c&state=now'),
          callbackPath: path,
          expectedState: 'now',
        ),
        isTrue,
      );
      expect(
        isExpectedOAuthCallback(
          cb('error=access_denied&state=now'),
          callbackPath: path,
          expectedState: 'now',
        ),
        isTrue,
        reason: '拒否も今回の試行の応答（#620 の自己回復へ進む）',
      );
    });

    test('⚠⚠ Mastodon: 前回の state の callback は受け取らない', () {
      expect(
        isExpectedOAuthCallback(
          cb('code=old&state=before'),
          callbackPath: path,
          expectedState: 'now',
        ),
        isFalse,
      );
      expect(
        isExpectedOAuthCallback(
          cb('code=old'),
          callbackPath: path,
          expectedState: 'now',
        ),
        isFalse,
        reason: 'state が無いものも今回の応答とはみなさない',
      );
    });

    test('Misskey: 今回の session なら受け取る', () {
      expect(
        isExpectedOAuthCallback(
          cb('session=now'),
          callbackPath: path,
          expectedSession: 'now',
        ),
        isTrue,
      );
    });

    test('⚠⚠ Misskey: 前回の session の callback は受け取らない', () {
      // #1140 の Linux の実測で、復元されたのはまさにこの形だった。受け取ると
      // 今回の session で /check をポーリングし、未承認のまま枯渇する。
      expect(
        isExpectedOAuthCallback(
          cb('session=before'),
          callbackPath: path,
          expectedSession: 'now',
        ),
        isFalse,
      );
    });

    test('⚠ Mastodon の試行に Misskey の前回 callback が来ても受け取らない', () {
      // 前回は別サーバー（Misskey）へログインしていた、という並び。
      expect(
        isExpectedOAuthCallback(
          cb('session=before'),
          callbackPath: path,
          expectedState: 'now',
        ),
        isFalse,
      );
    });

    test('パス違い・クエリ無しは対象外', () {
      expect(
        isExpectedOAuthCallback(
          Uri.parse('http://localhost:7099/favicon.ico'),
          callbackPath: path,
        ),
        isFalse,
      );
      expect(
        isExpectedOAuthCallback(
          Uri.parse('http://localhost:7099$path'),
          callbackPath: path,
        ),
        isFalse,
      );
    });
  });
}
