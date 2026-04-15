import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Collects and persists iOS background-task diagnostics for #293.
///
/// This service does NOT depend on Riverpod, so it can also be called from
/// the workmanager background isolate (via [recordTaskFired] /
/// [recordTaskCompleted]).
class NotificationDiagnosticsService {
  // SharedPreferences keys.
  static const _fireCountKey = 'capsicum_diag_bg_fire_count';
  static const _lastFireKey = 'capsicum_diag_bg_last_fire';
  static const _lastSuccessKey = 'capsicum_diag_bg_last_success';
  static const _lastFailureReasonKey = 'capsicum_diag_bg_last_failure_reason';

  // --- Background task instrumentation ---

  /// Call at the very start of the background dispatcher callback.
  static Future<void> recordTaskFired() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_fireCountKey) ?? 0;
    final now = DateTime.now().toIso8601String();

    await prefs.setInt(_fireCountKey, count + 1);
    await prefs.setString(_lastFireKey, now);

    Sentry.addBreadcrumb(Breadcrumb(
      message: 'BGTask fired',
      category: 'notification.background',
      data: {'fireCount': count + 1},
    ));

    // Capture a message on the first ever firing so we know the task works.
    if (count == 0) {
      await Sentry.captureMessage(
        'BGTask fired for the first time',
        level: SentryLevel.info,
      );
    }
  }

  /// Call when `checkAllAccounts` completes successfully.
  static Future<void> recordTaskCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toIso8601String();
    await prefs.setString(_lastSuccessKey, now);
    await prefs.remove(_lastFailureReasonKey);

    Sentry.addBreadcrumb(Breadcrumb(
      message: 'BGTask completed successfully',
      category: 'notification.background',
    ));
  }

  /// Call when `checkAllAccounts` fails or the task expires.
  static Future<void> recordTaskFailed(String reason) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastFailureReasonKey, reason);

    Sentry.addBreadcrumb(Breadcrumb(
      message: 'BGTask failed',
      category: 'notification.background',
      data: {'reason': reason},
      level: SentryLevel.warning,
    ));
  }

  // --- Diagnostic data for the settings UI ---

  /// Returns a snapshot of all persisted diagnostics.
  static Future<DiagnosticsSnapshot> getSnapshot() async {
    final prefs = await SharedPreferences.getInstance();

    return DiagnosticsSnapshot(
      fireCount: prefs.getInt(_fireCountKey) ?? 0,
      lastFireTime: _parseDateTime(prefs.getString(_lastFireKey)),
      lastSuccessTime: _parseDateTime(prefs.getString(_lastSuccessKey)),
      lastFailureReason: prefs.getString(_lastFailureReasonKey),
    );
  }

  static DateTime? _parseDateTime(String? s) =>
      s != null ? DateTime.tryParse(s) : null;
}

/// Immutable snapshot of notification diagnostics for display.
class DiagnosticsSnapshot {
  final int fireCount;
  final DateTime? lastFireTime;
  final DateTime? lastSuccessTime;
  final String? lastFailureReason;

  const DiagnosticsSnapshot({
    required this.fireCount,
    required this.lastFireTime,
    required this.lastSuccessTime,
    this.lastFailureReason,
  });
}
