import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'background_task_scheduler.dart';

/// macOS / Linux / Windows 向け実装。Dart の [Timer.periodic] を使った
/// アプリ常駐前提のスケジューラ。OS のバックグラウンド実行 API は
/// プラットフォームごとに異なる（macOS は launchd、Linux は systemd、
/// Windows は Task Scheduler）が、capsicum のデスクトップ用途では
/// 「アプリが開いている間だけポーリング」で十分な見込みのため、まず
/// この軽量実装を入れる。アプリ終了時に登録は失効する。
class TimerBackgroundTaskScheduler
    with WidgetsBindingObserver
    implements BackgroundTaskScheduler {
  final Map<String, Timer> _timers = {};
  // Timer.periodic は前回 callback が in-flight でも次の tick を発火する。
  // interval が短く callback が遅いと多重実行になるため、taskId 単位の
  // in-flight ガードで再入を防ぐ。
  final Map<String, bool> _inFlight = {};
  bool _observing = false;

  @override
  Future<void> registerPeriodic({
    required String taskId,
    required Duration interval,
    required Future<void> Function() callback,
  }) async {
    _ensureLifecycleObserver();
    _timers.remove(taskId)?.cancel();
    _inFlight.remove(taskId);
    _timers[taskId] = Timer.periodic(interval, (_) async {
      if (_inFlight[taskId] == true) return;
      _inFlight[taskId] = true;
      try {
        await callback();
      } catch (e, st) {
        // スケジューラは次回 interval まで待たせ、ここで例外を握って
        // タスクを止めない。観測層で taskId 単位にグループしておく。
        debugPrint(
          'capsicum: background_task: callback failed (taskId=$taskId): $e\n$st',
        );
        try {
          await Sentry.captureException(
            e,
            stackTrace: st,
            withScope: (scope) {
              scope.setTag('background_task.id', taskId);
              scope.fingerprint = ['background_task', taskId];
            },
          );
        } catch (_) {
          // Sentry 自体の失敗で次回発火を止めない。
        }
      } finally {
        _inFlight[taskId] = false;
      }
    });
  }

  @override
  Future<void> cancel(String taskId) async {
    _timers.remove(taskId)?.cancel();
    _inFlight.remove(taskId);
  }

  /// アプリが [AppLifecycleState.detached] に至ったタイミングで登録済み
  /// タスクをまとめて取り消す。デスクトップでホットリロード・再起動を
  /// 跨ぐとプロセスは生き続けることがあり、Timer の残骸が次世代の登録と
  /// 重複して二重発火するのを避ける目的。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      cancelAll();
    }
  }

  void _ensureLifecycleObserver() {
    if (_observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  /// 全タスクを取り消す。lifecycle (detached) 経路と、テストでの
  /// tear-down ヘルパーでのみ使う。consumer から直接呼ぶ用途は今のところ
  /// なく、必要になれば [BackgroundTaskScheduler] interface への昇格を検討する。
  @visibleForTesting
  void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _inFlight.clear();
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }
}
