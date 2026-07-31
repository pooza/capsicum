import 'dart:async';

import 'package:capsicum/src/util/reentrancy_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// #908: 投稿の送信は、UI 無効化に使う `_sending` を立てるより前に確認設定の
/// 読み出し（SharedPreferences）を await していたため、その往復の間に二連打すると
/// 二重投稿になりえた。ガードが「最初の await より前に同期的に」閉じることを固める。
void main() {
  group('ReentrancyGuard', () {
    test('走行中の再呼び出しは実行されない（二重投稿を弾く）', () async {
      final guard = ReentrancyGuard();
      final gate = Completer<void>();
      var runs = 0;

      Future<void> action() async {
        runs++;
        await gate.future;
      }

      // 1 回目を走らせたまま、2 回目・3 回目を叩く。
      final first = guard.run(action);
      await guard.run(action);
      await guard.run(action);
      expect(runs, 1);

      gate.complete();
      await first;
      expect(runs, 1);
    });

    test('最初の await より前に閉じる（await 前の窓が無い）', () async {
      final guard = ReentrancyGuard();
      var runs = 0;

      // 呼び出し直後（await を挟まず）にもう一度叩く状況＝素早い二連打。
      unawaited(
        guard.run(() async {
          runs++;
          await Future<void>.delayed(Duration.zero);
        }),
      );
      unawaited(guard.run(() async => runs++));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(runs, 1);
    });

    test('完了後は再び実行できる（送信のたびに使える）', () async {
      final guard = ReentrancyGuard();
      var runs = 0;

      await guard.run(() async => runs++);
      await guard.run(() async => runs++);
      expect(runs, 2);
    });

    test('例外が出てもフラグは戻る（次の送信が永久に弾かれない）', () async {
      final guard = ReentrancyGuard();
      var runs = 0;

      await expectLater(
        guard.run(() async {
          runs++;
          throw Exception('post failed');
        }),
        throwsException,
      );
      expect(guard.inFlight, isFalse);

      await guard.run(() async => runs++);
      expect(runs, 2);
    });

    test('inFlight で走行中を問い合わせられる', () async {
      final guard = ReentrancyGuard();
      final gate = Completer<void>();

      expect(guard.inFlight, isFalse);
      final running = guard.run(() => gate.future);
      expect(guard.inFlight, isTrue);

      gate.complete();
      await running;
      expect(guard.inFlight, isFalse);
    });
  });
}
