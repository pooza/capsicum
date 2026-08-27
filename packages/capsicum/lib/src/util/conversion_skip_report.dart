import 'package:capsicum_core/capsicum_core.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 通知の変換失敗（malformed・#741 の Collections 通知等）を Sentry に記録する。
///
/// timeline 側の `_reportSkippedPosts` (#777) と対称に、通知でも変換スキップを
/// 黙って捨てず観測する。これがないと `NotificationResponse.skippedPosts` が
/// 存在意義に挙げる #741 のケースが本番で完全に不可視になる。投稿 ID と変換
/// エラー文字列のみ送り、本文は載せない（timeline と同等の scrub 水準）。
/// [source] で発生元（single / unified）を区別し、[maxId] はページング位置。
void reportSkippedNotifications(
  List<SkippedPost> skipped, {
  required String source,
  String? maxId,
}) {
  if (skipped.isEmpty) return;
  try {
    for (final item in skipped) {
      // params は logentry.params として実際に送られる（hint は送られない）ので、
      // ここが変換失敗の唯一の観測経路 (#1027-A5)。
      // scrub-guard: allow: item.error は describeConversionFailure 済み（本文なし）
      Sentry.captureMessage(
        'Notification conversion failed',
        level: SentryLevel.warning,
        params: [item.id, item.error],
        hint: Hint.withMap({
          'source': source,
          'skippedNotificationId': item.id,
          'conversionError': item.error,
          'maxId': maxId ?? 'null',
        }),
      );
    }
  } catch (_) {
    // Sentry failure must not affect notification loading.
  }
}
