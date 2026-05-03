import 'background_task_scheduler.dart';

/// iOS / Android 向け実装。capsicum のモバイル経路は APNs / FCM プッシュ
/// 通知リレーに一本化されているため、バックグラウンドポーリング相当の
/// 機能は不要で no-op として動作する。
///
/// 将来モバイル側でもポーリングが必要になった場合は workmanager 等の
/// 復活ではなくこの実装を差し替える形で対応する。
class NoopBackgroundTaskScheduler implements BackgroundTaskScheduler {
  @override
  Future<void> registerPeriodic({
    required String taskId,
    required Duration interval,
    required Future<void> Function() callback,
  }) async {
    // no-op
  }

  @override
  Future<void> cancel(String taskId) async {
    // no-op
  }
}
