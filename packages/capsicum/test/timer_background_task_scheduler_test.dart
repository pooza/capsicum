import 'package:capsicum/src/platform/background_task/timer_background_task_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TimerBackgroundTaskScheduler (#328)', () {
    test('登録した callback が周期で呼ばれる', () async {
      final scheduler = TimerBackgroundTaskScheduler();
      addTearDown(scheduler.cancelAll);

      var calls = 0;
      await scheduler.registerPeriodic(
        taskId: 'tick',
        interval: const Duration(milliseconds: 20),
        callback: () async {
          calls++;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(calls, greaterThanOrEqualTo(2));
    });

    test('同一 taskId を再登録すると前回登録は破棄される', () async {
      final scheduler = TimerBackgroundTaskScheduler();
      addTearDown(scheduler.cancelAll);

      var first = 0;
      var second = 0;

      await scheduler.registerPeriodic(
        taskId: 'tick',
        interval: const Duration(milliseconds: 20),
        callback: () async => first++,
      );
      await scheduler.registerPeriodic(
        taskId: 'tick',
        interval: const Duration(milliseconds: 20),
        callback: () async => second++,
      );

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(first, 0);
      expect(second, greaterThanOrEqualTo(2));
    });

    test('cancel すると次回以降発火しない', () async {
      final scheduler = TimerBackgroundTaskScheduler();
      addTearDown(scheduler.cancelAll);

      var calls = 0;
      await scheduler.registerPeriodic(
        taskId: 'tick',
        interval: const Duration(milliseconds: 20),
        callback: () async => calls++,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final captured = calls;
      await scheduler.cancel('tick');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, captured);
    });

    test('callback が例外を投げてもスケジューラは停止しない', () async {
      final scheduler = TimerBackgroundTaskScheduler();
      addTearDown(scheduler.cancelAll);

      var calls = 0;
      await scheduler.registerPeriodic(
        taskId: 'tick',
        interval: const Duration(milliseconds: 20),
        callback: () async {
          calls++;
          throw StateError('boom');
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(calls, greaterThanOrEqualTo(2));
    });
  });
}
