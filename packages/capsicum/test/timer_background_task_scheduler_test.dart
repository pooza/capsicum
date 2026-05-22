import 'package:capsicum/src/platform/background_task/timer_background_task_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // WidgetsBindingObserver を attach するため、binding を初期化しておく。
  TestWidgetsFlutterBinding.ensureInitialized();

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

    test('前世代 callback が in-flight 中に再登録しても新世代の再入は防がれる (#505)', () async {
      // 旧実装 (Set<String>) では、前世代 callback の finally が新世代の
      // in-flight マーカ (taskId キー) を誤って外し、新世代が並列実行
      // する race があった。世代トークン化でこれが起きないことを確認する。
      final scheduler = TimerBackgroundTaskScheduler();
      addTearDown(scheduler.cancelAll);

      var firstStarted = 0;
      // 前世代: 長めの callback で in-flight を引き伸ばす。
      await scheduler.registerPeriodic(
        taskId: 'gen',
        interval: const Duration(milliseconds: 20),
        callback: () async {
          firstStarted++;
          await Future<void>.delayed(const Duration(milliseconds: 80));
        },
      );

      // 前世代の callback が走り始めてから再登録する。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(firstStarted, greaterThanOrEqualTo(1));

      var secondConcurrent = 0;
      var secondMaxConcurrent = 0;
      await scheduler.registerPeriodic(
        taskId: 'gen',
        interval: const Duration(milliseconds: 10),
        callback: () async {
          secondConcurrent++;
          if (secondConcurrent > secondMaxConcurrent) {
            secondMaxConcurrent = secondConcurrent;
          }
          // 新世代も短くないと観測しづらいので、interval よりは長く取る。
          await Future<void>.delayed(const Duration(milliseconds: 50));
          secondConcurrent--;
        },
      );

      // 旧実装では前世代の finally で in-flight が解除され、新世代が
      // 並列発火する。世代トークン化されていれば maxConcurrent は 1。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(secondMaxConcurrent, 1);
    });

    test('callback が in-flight の間は次の tick で再入しない', () async {
      // interval (10ms) より callback (50ms) が長いケースで、Timer.periodic の
      // 素朴な発火に任せると並列実行が起きる。in-flight ガードによって
      // 同時実行数が 1 を超えないことを確認する。
      final scheduler = TimerBackgroundTaskScheduler();
      addTearDown(scheduler.cancelAll);

      var concurrent = 0;
      var maxConcurrent = 0;
      await scheduler.registerPeriodic(
        taskId: 'slow',
        interval: const Duration(milliseconds: 10),
        callback: () async {
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          concurrent--;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(maxConcurrent, 1);
    });
  });
}
