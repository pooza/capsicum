/// プラットフォーム差を吸収するバックグラウンドタスクスケジューラ (#328)。
///
/// モバイル (iOS / Android) は APNs / FCM プッシュ通知リレー (#52) に
/// 一本化済みで、workmanager 由来のバックグラウンドポーリングは v1.19
/// (#348) で撤去されている。デスクトップは push 受信経路がないため、
/// 通知ポーリング相当を Dart `Timer` + 常駐前提で組む必要がある。
///
/// 本抽象は v1.23 で interface と各プラットフォーム実装を先に揃え、
/// 実際の利用箇所（デスクトップ向け通知ポーリング等）は v1.24 の
/// Linux / Windows 着手時に組み込む scaffolding 段階。
abstract class BackgroundTaskScheduler {
  /// 周期実行タスクを登録する。同一 [taskId] を再登録した場合は前回の
  /// 登録が破棄されて差し替えられる（モバイル no-op 実装でも同セマンティクス）。
  ///
  /// [callback] は async で、完了するまで次の発火を待つ。例外を投げても
  /// スケジューラは止まらない（次回 interval で再試行）。
  Future<void> registerPeriodic({
    required String taskId,
    required Duration interval,
    required Future<void> Function() callback,
  });

  /// 登録済みタスクを取り消す。未登録の [taskId] でも例外は出さない。
  Future<void> cancel(String taskId);
}
