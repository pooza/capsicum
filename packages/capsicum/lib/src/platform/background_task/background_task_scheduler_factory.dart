import 'dart:io' show Platform;

import 'background_task_scheduler.dart';
import 'noop_background_task_scheduler.dart';
import 'timer_background_task_scheduler.dart';

/// プラットフォームに応じた [BackgroundTaskScheduler] 実装を生成する。
///
/// モバイルはプッシュ通知リレーに一本化済みで、デスクトップは push 受信
/// 経路がないため Timer 常駐で代替する、という方針 (CLAUDE.md
/// デスクトップ対応 第2段階) に従う。
BackgroundTaskScheduler createBackgroundTaskScheduler() {
  if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
    return TimerBackgroundTaskScheduler();
  }
  return NoopBackgroundTaskScheduler();
}
