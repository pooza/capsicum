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
  static const _prefixHost = 'capsicum_push_failure_last_host';
  static const _prefixEncoding = 'capsicum_push_failure_last_encoding';
  static const _prefixElapsedMs = 'capsicum_push_failure_last_elapsed_ms';
  // #436: nse.no_keys の根本原因切り分け用。
  static const _prefixKeychainStatus =
      'capsicum_push_failure_last_keychain_status';
  static const _prefixTriedPrefixes =
      'capsicum_push_failure_last_tried_prefixes';

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
  ///
  /// [host] / [encoding] / [elapsedMs] は #376 で追加した切り分け用コンテキスト。
  /// 自前 / 他鯖 / 暗号化方式 / NSE 経過時間（タイムアウト由来かどうか）を
  /// Sentry tag/extra で見るために使う。`bg_handler.failed` のように context が
  /// 取れない経路では省略可。
  ///
  /// [keychainStatus] / [triedPrefixes] は #436 で追加した nse.no_keys 切り分け用。
  /// iOS NSE が Keychain から鍵を読めなかった原因（OSStatus と試行したプレフィックス）を
  /// Sentry tag に乗せる。NSE 由来でない経路では省略可。
  static Future<void> record(
    String code, {
    String? host,
    String? encoding,
    int? elapsedMs,
    int? keychainStatus,
    String? triedPrefixes,
  }) async {
    try {
      final prefs = _prefs();
      await prefs.setString(_prefixCode, code);
      await prefs.setInt(_prefixAt, DateTime.now().millisecondsSinceEpoch);
      final current = await prefs.getInt(_prefixCount) ?? 0;
      await prefs.setInt(_prefixCount, current + 1);
      if (host != null) {
        await prefs.setString(_prefixHost, host);
      } else {
        await prefs.remove(_prefixHost);
      }
      if (encoding != null) {
        await prefs.setString(_prefixEncoding, encoding);
      } else {
        await prefs.remove(_prefixEncoding);
      }
      if (elapsedMs != null) {
        await prefs.setInt(_prefixElapsedMs, elapsedMs);
      } else {
        await prefs.remove(_prefixElapsedMs);
      }
      if (keychainStatus != null) {
        await prefs.setInt(_prefixKeychainStatus, keychainStatus);
      } else {
        await prefs.remove(_prefixKeychainStatus);
      }
      if (triedPrefixes != null) {
        await prefs.setString(_prefixTriedPrefixes, triedPrefixes);
      } else {
        await prefs.remove(_prefixTriedPrefixes);
      }
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
      final host = await prefs.getString(_prefixHost);
      final encoding = await prefs.getString(_prefixEncoding);
      final elapsedMs = await prefs.getInt(_prefixElapsedMs);
      final keychainStatus = await prefs.getInt(_prefixKeychainStatus);
      final triedPrefixes = await prefs.getString(_prefixTriedPrefixes);
      await prefs.remove(_prefixCode);
      await prefs.remove(_prefixAt);
      await prefs.remove(_prefixCount);
      await prefs.remove(_prefixHost);
      await prefs.remove(_prefixEncoding);
      await prefs.remove(_prefixElapsedMs);
      await prefs.remove(_prefixKeychainStatus);
      await prefs.remove(_prefixTriedPrefixes);
      return PushFailureRecord(
        code: code,
        at: atMs != null
            ? DateTime.fromMillisecondsSinceEpoch(atMs)
            : DateTime.now(),
        count: count,
        host: host,
        encoding: encoding,
        elapsedMs: elapsedMs,
        keychainStatus: keychainStatus,
        triedPrefixes: triedPrefixes,
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
  final String? host;
  final String? encoding;
  final int? elapsedMs;

  /// iOS Keychain `SecItemCopyMatching` の OSStatus。`nse.no_keys` の根本
  /// 原因切り分けに使う (#436)。NSE 由来でない経路では null。
  final int? keychainStatus;

  /// PushKeyReader が試行したストレージキープレフィックス（"mastodon,misskey" 等）。
  /// 失敗時にどこまで試したかを Sentry で把握するため (#436)。
  final String? triedPrefixes;

  const PushFailureRecord({
    required this.code,
    required this.at,
    required this.count,
    this.host,
    this.encoding,
    this.elapsedMs,
    this.keychainStatus,
    this.triedPrefixes,
  });
}
