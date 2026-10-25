/// 通知のタップから画面を開くまでの待ちの上限 (#1332)。
///
/// ⚠⚠ **フレームの数だけで切らない。**以前は 3600 フレーム（≒ 60 秒 @60fps）が
/// 上限で、描画が止まっている間（裏へ回した・画面を消した）は進まなかった。
/// 宛先のアカウントがずっと後で戻った時点で `switchAccount` + `go('/home')` が
/// 走り、その間に開いていた投稿フォーム等を置き換えた。
library;

/// 通知の経路を待つ上限のフレーム数（session の復元と Navigator の確立待ち）。
const notificationRouteMaxAttempts = 3600;

/// 通知の経路全体を待つ実時間の上限。
const notificationRouteDeadline = Duration(seconds: 60);

/// 宛先のアカウントが再試行で戻るのを待つ実時間の上限。過ぎたら今のアカウントで
/// 開く（#1304 の従来どおり）。
///
/// ⚠ **待ち始めてから数える**（タップからではない）。起動の締切
/// （`kRestoreStartupDeadline` = 10 秒）で session の復元を待つだけで、タップ
/// からの時間は使い切りうる。長さは背景の再試行の立ち上がり（2・5・15 秒・
/// `kOfflineRetryRampUp`）が 3 回走るぶん。⚠ 全体の上限より短くする —— 待って
/// いる間に利用者は別の画面へ移っている。
const notificationRecoveryWait = Duration(seconds: 30);

/// 通知の経路を諦めるか。フレームの数か実時間のどちらかが上限に達したら諦める。
bool notificationRouteExpired({
  required int attempt,
  required Duration elapsed,
}) =>
    attempt >= notificationRouteMaxAttempts ||
    elapsed >= notificationRouteDeadline;

/// 宛先のアカウントの復旧をまだ待ってよいか。
bool notificationRecoveryStillWaiting(Duration elapsed) =>
    elapsed < notificationRecoveryWait;

/// 通知のタップ 1 回ぶんの経路 (#1332)。
///
/// ⚠ **新しいタップが来たら古い経路は捨てる。**待っている間に別の通知を
/// タップすると経路が 2 本並び、あとから戻った古いほうが新しいほうを上書き
/// していた。[NotificationRouteTicket.issue] で世代を進め、待ちの再開のたびに
/// [isCurrent] を見る。
class NotificationRouteTicket {
  NotificationRouteTicket._(
    this.generation,
    this._stopwatch,
    this._startedAt,
    this._now,
  );

  static int _latest = 0;

  /// 新しいタップの経路を始める（それより前の経路は [isCurrent] が偽になる）。
  ///
  /// [now] はテストの差し替え口。
  factory NotificationRouteTicket.issue({DateTime Function()? now}) {
    final clock = now ?? DateTime.now;
    return NotificationRouteTicket._(
      ++_latest,
      Stopwatch()..start(),
      clock(),
      clock,
    );
  }

  final int generation;
  final Stopwatch _stopwatch;
  final DateTime _startedAt;
  final DateTime Function() _now;

  /// 最新のタップの経路か。
  bool get isCurrent => generation == _latest;

  /// タップからの経過時間。
  ///
  /// ⚠⚠ **端末のスリープ中も数える。**[Stopwatch] は単調時計なので、画面を
  /// 消している間は進まない。壁時計の経過と大きいほうを取る（壁時計は手で
  /// 戻されうるので、それだけには頼らない）。
  Duration get elapsed {
    final wall = _now().difference(_startedAt);
    final mono = _stopwatch.elapsed;
    return wall > mono ? wall : mono;
  }

  Duration? _recoveryStartedAt;

  /// 宛先のアカウントの復旧を待ち始めてからの経過時間。初めて呼んだ時点から
  /// 数える。
  Duration recoveryElapsed() {
    final now = elapsed;
    return now - (_recoveryStartedAt ??= now);
  }
}
