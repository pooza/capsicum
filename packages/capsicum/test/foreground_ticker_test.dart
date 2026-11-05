import 'package:capsicum/src/service/foreground_ticker.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// #910: モバイルで前面に居続けている間、お知らせを取り直す機会が無かった。
void main() {
  const interval = Duration(minutes: 15);

  test('前面にいる間は間隔ごとに呼ぶ', () {
    fakeAsync((async) {
      var ticks = 0;
      final ticker = ForegroundTicker(interval: interval, onTick: () => ticks++)
        ..start();

      async.elapse(const Duration(minutes: 14));
      expect(ticks, 0);
      async.elapse(const Duration(minutes: 1));
      expect(ticks, 1);
      async.elapse(interval);
      expect(ticks, 2);
      ticker.stop();
    });
  });

  test('⚠⚠ 背面では呼ばない（電池に見合わない）', () {
    fakeAsync((async) {
      var ticks = 0;
      final ticker = ForegroundTicker(interval: interval, onTick: () => ticks++)
        ..start();

      ticker.handleLifecycle(AppLifecycleState.paused);
      async.elapse(const Duration(hours: 2));

      expect(ticks, 0);
      expect(ticker.isRunning, isFalse);
    });
  });

  test('戻ったら間隔を数え直す', () {
    fakeAsync((async) {
      var ticks = 0;
      final ticker = ForegroundTicker(interval: interval, onTick: () => ticks++)
        ..start();
      async.elapse(const Duration(minutes: 14));
      ticker.handleLifecycle(AppLifecycleState.hidden);

      ticker.handleLifecycle(AppLifecycleState.resumed);
      async.elapse(const Duration(minutes: 14));
      expect(ticks, 0);
      async.elapse(const Duration(minutes: 1));
      expect(ticks, 1);
      ticker.stop();
    });
  });

  test('inactive では止めない', () {
    fakeAsync((async) {
      var ticks = 0;
      final ticker = ForegroundTicker(interval: interval, onTick: () => ticks++)
        ..start();

      ticker.handleLifecycle(AppLifecycleState.inactive);
      async.elapse(interval);

      expect(ticks, 1);
      ticker.stop();
    });
  });

  // #1361: 画面が作り直されたときの始め方。
  group('startIfResumed', () {
    for (final (state, runs) in [
      (AppLifecycleState.resumed, true),
      (null, true),
      (AppLifecycleState.paused, false),
      (AppLifecycleState.hidden, false),
      (AppLifecycleState.inactive, false),
      (AppLifecycleState.detached, false),
    ]) {
      test('$state なら ${runs ? '始める' : '⚠ 始めない（裏で取り直し続ける）'}', () {
        final ticker = ForegroundTicker(interval: interval, onTick: () {})
          ..startIfResumed(state);
        addTearDown(ticker.stop);

        expect(ticker.isRunning, runs);
      });
    }

    test('裏で始めなかったものも、前面へ戻れば動く', () {
      final ticker = ForegroundTicker(interval: interval, onTick: () {})
        ..startIfResumed(AppLifecycleState.paused)
        ..handleLifecycle(AppLifecycleState.resumed);
      addTearDown(ticker.stop);

      expect(ticker.isRunning, isTrue);
    });
  });
}
