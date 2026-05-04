import 'dart:async';

import 'package:flutter/foundation.dart';

import 'background_task_scheduler.dart';

/// macOS / Linux / Windows 向け実装。Dart の [Timer.periodic] を使った
/// アプリ常駐前提のスケジューラ。OS のバックグラウンド実行 API は
/// プラットフォームごとに異なる（macOS は launchd、Linux は systemd、
/// Windows は Task Scheduler）が、capsicum のデスクトップ用途では
/// 「アプリが開いている間だけポーリング」で十分な見込みのため、まず
/// この軽量実装を入れる。アプリ終了時に登録は失効する。
class TimerBackgroundTaskScheduler implements BackgroundTaskScheduler {
  final Map<String, Timer> _timers = {};

  @override
  Future<void> registerPeriodic({
    required String taskId,
    required Duration interval,
    required Future<void> Function() callback,
  }) async {
    _timers.remove(taskId)?.cancel();
    _timers[taskId] = Timer.periodic(interval, (_) async {
      try {
        await callback();
      } catch (e, st) {
        // スケジューラは次回 interval まで待たせ、ここで例外を握って
        // タスクを止めない。観測は呼び出し側 (Sentry 等) の責務。
        debugPrint(
          'capsicum: background_task: callback failed (taskId=$taskId): $e\n$st',
        );
      }
    });
  }

  @override
  Future<void> cancel(String taskId) async {
    _timers.remove(taskId)?.cancel();
  }

  /// 全タスクを取り消す。アプリ終了時のクリーンアップ用。テストで
  /// 登録済みタスクをまとめてリセットする際にも使う。
  void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}
