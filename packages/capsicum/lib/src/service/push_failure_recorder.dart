import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_foundation/shared_preferences_foundation.dart';

import 'notification_label_cache.dart';

/// バックグラウンド isolate（Android FCM `onBackgroundMessage`）と
/// iOS Notification Service Extension で発生した復号 / 鍵不在等の失敗を
/// 永続化し、次回 main app 起動時に Sentry へ吸い上げるためのレコーダー (#366)。
///
/// 設計の前提:
/// - バックグラウンド isolate / NSE では Sentry SDK を初期化していないため
///   その場で `captureException` を呼べない。`debugPrint` / `NSLog` に流すと
///   ユーザー報告経由でしか観測できない（ログを引き出すのはコスト大）。
/// - 復号失敗が永続化しても main app は沈黙してしまう盲目状態を解消する。
///
/// ストレージ:
/// - Android / iOS とも `SharedPreferencesAsync` を使う。iOS は App Group
///   suiteName で NSE 側 `UserDefaults(suiteName:)` と同一空間を共有する
///   （[NotificationLabelCache] と同じ仕組み）。
/// - レコードは「最後に発生したコード + 件数 + 最終発生時刻」のみ保持し、
///   個別イベントの履歴は残さない。volume を抑え、main app 起動時に 1 回
///   `captureMessage` で吸い上げる。
class PushFailureRecorder {
  static const _prefixCode = 'capsicum_push_failure_last_code';
  static const _prefixAt = 'capsicum_push_failure_last_at_ms';
  static const _prefixCount = 'capsicum_push_failure_count';

  /// `dispatch.*`: Android FCM バックグラウンド isolate
  /// `nse.*`: iOS Notification Service Extension（NSE 側で書く）
  /// `bg_handler.*`: `_firebaseBackgroundMessageHandler` 自体の致命例外
  static const codeNoKeys = 'dispatch.no_keys';
  static const codeDecryptFailed = 'dispatch.decrypt_failed';
  static const codeParseFailed = 'dispatch.parse_failed';
  static const codeHandlerFailed = 'bg_handler.failed';

  static SharedPreferencesAsync _prefs() => SharedPreferencesAsync(
    options: Platform.isIOS || Platform.isMacOS
        ? SharedPreferencesAsyncFoundationOptions(
            suiteName: NotificationLabelCache.appGroupId,
          )
        : const SharedPreferencesOptions(),
  );

  /// 失敗を記録する。バックグラウンド isolate から呼ぶ前提。例外は握りつぶす
  /// （観測のための処理が通知本体を巻き込むことを避ける）。
  static Future<void> record(String code) async {
    try {
      final prefs = _prefs();
      await prefs.setString(_prefixCode, code);
      await prefs.setInt(_prefixAt, DateTime.now().millisecondsSinceEpoch);
      final current = await prefs.getInt(_prefixCount) ?? 0;
      await prefs.setInt(_prefixCount, current + 1);
    } catch (_) {
      // ignore: 観測機構の失敗で本体を落とさない
    }
  }

  /// 永続化済みのレコードを 1 件返してクリアする。main app 起動時に呼び、
  /// Sentry に吸い上げる。エントリが無い場合は `null`。
  static Future<PushFailureRecord?> consume() async {
    try {
      final prefs = _prefs();
      final code = await prefs.getString(_prefixCode);
      if (code == null) return null;
      final atMs = await prefs.getInt(_prefixAt);
      final count = await prefs.getInt(_prefixCount) ?? 0;
      await prefs.remove(_prefixCode);
      await prefs.remove(_prefixAt);
      await prefs.remove(_prefixCount);
      return PushFailureRecord(
        code: code,
        at: atMs != null
            ? DateTime.fromMillisecondsSinceEpoch(atMs)
            : DateTime.now(),
        count: count,
      );
    } catch (_) {
      return null;
    }
  }
}

class PushFailureRecord {
  final String code;
  final DateTime at;
  final int count;

  const PushFailureRecord({
    required this.code,
    required this.at,
    required this.count,
  });
}
