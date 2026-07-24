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
}
