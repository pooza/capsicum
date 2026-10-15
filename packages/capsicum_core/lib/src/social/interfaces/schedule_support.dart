import '../../model/scheduled_post.dart';

abstract mixin class ScheduleSupport {
  Future<List<ScheduledPost>> getScheduledPosts();
  Future<void> cancelScheduledPost(String id);

  /// 予約投稿の時刻を変える (#1212)。本文・添付などはそのまま。
  ///
  /// ⚠ **サーバーの下限より手前の時刻は拒まれる**（Mastodon は 5 分後以降・
  /// Misskey は未来であること）。呼ぶ側のピッカーで先に弾く。
  Future<void> rescheduleScheduledPost(String id, DateTime scheduledAt);
}
