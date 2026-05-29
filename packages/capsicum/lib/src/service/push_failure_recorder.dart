import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_foundation/shared_preferences_foundation.dart';

import 'notification_label_cache.dart';

/// [PushFailureRecorder] が App Group / SharedPreferences に書き込む 1 スロット
/// 分のキー集合。iOS NSE 側（`FailureRecorder` in `NotificationService.swift`）
/// と完全同名で対応している。新しい項目を増やすときは両側を揃えること。
enum PushFailureKey {
  code('capsicum_push_failure_last_code'),
  at('capsicum_push_failure_last_at_ms'),
  count('capsicum_push_failure_count'),
  host('capsicum_push_failure_last_host'),
  encoding('capsicum_push_failure_last_encoding'),
  elapsedMs('capsicum_push_failure_last_elapsed_ms'),
  // #436: nse.no_keys の根本原因切り分け用。
  keychainStatus('capsicum_push_failure_last_keychain_status'),
  triedPrefixes('capsicum_push_failure_last_tried_prefixes'),
  // #436: nse.decrypt_failed の切り分け用。WebPushDecryptor / CryptoKit が
  // 投げた error の type + case 名。
  decryptError('capsicum_push_failure_last_decrypt_error');

  const PushFailureKey(this.storageKey);

  final String storageKey;
}

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
  ///
  /// [decryptError] は #436 で追加した nse.decrypt_failed 切り分け用。
  /// WebPushDecryptor / CryptoKit が投げた error の type + case 名
  /// （"WebPushError.invalidKeyId" / "CryptoKitError.authenticationFailure" 等）。
  static Future<void> record(
    String code, {
    String? host,
    String? encoding,
    int? elapsedMs,
    int? keychainStatus,
    String? triedPrefixes,
    String? decryptError,
  }) async {
    try {
      final prefs = _prefs();
      await prefs.setString(PushFailureKey.code.storageKey, code);
      await prefs.setInt(
        PushFailureKey.at.storageKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      final current = await prefs.getInt(PushFailureKey.count.storageKey) ?? 0;
      await prefs.setInt(PushFailureKey.count.storageKey, current + 1);
      await _writeOptionalString(prefs, PushFailureKey.host, host);
      await _writeOptionalString(prefs, PushFailureKey.encoding, encoding);
      await _writeOptionalInt(prefs, PushFailureKey.elapsedMs, elapsedMs);
      await _writeOptionalInt(
        prefs,
        PushFailureKey.keychainStatus,
        keychainStatus,
      );
      await _writeOptionalString(
        prefs,
        PushFailureKey.triedPrefixes,
        triedPrefixes,
      );
      await _writeOptionalString(
        prefs,
        PushFailureKey.decryptError,
        decryptError,
      );
    } catch (_) {
      // ignore: 観測機構の失敗で本体を落とさない
    }
  }

  static Future<void> _writeOptionalString(
    SharedPreferencesAsync prefs,
    PushFailureKey key,
    String? value,
  ) async {
    if (value != null) {
      await prefs.setString(key.storageKey, value);
    } else {
      await prefs.remove(key.storageKey);
    }
  }

  static Future<void> _writeOptionalInt(
    SharedPreferencesAsync prefs,
    PushFailureKey key,
    int? value,
  ) async {
    if (value != null) {
      await prefs.setInt(key.storageKey, value);
    } else {
      await prefs.remove(key.storageKey);
    }
  }

  /// 永続化済みのレコードを 1 件返してクリアする。main app 起動時に呼び、
  /// Sentry に吸い上げる。エントリが無い場合は `null`。
  static Future<PushFailureRecord?> consume() async {
    try {
      final prefs = _prefs();
      final code = await prefs.getString(PushFailureKey.code.storageKey);
      if (code == null) return null;
      final atMs = await prefs.getInt(PushFailureKey.at.storageKey);
      final count = await prefs.getInt(PushFailureKey.count.storageKey) ?? 0;
      final host = await prefs.getString(PushFailureKey.host.storageKey);
      final encoding = await prefs.getString(
        PushFailureKey.encoding.storageKey,
      );
      final elapsedMs = await prefs.getInt(PushFailureKey.elapsedMs.storageKey);
      final keychainStatus = await prefs.getInt(
        PushFailureKey.keychainStatus.storageKey,
      );
      final triedPrefixes = await prefs.getString(
        PushFailureKey.triedPrefixes.storageKey,
      );
      final decryptError = await prefs.getString(
        PushFailureKey.decryptError.storageKey,
      );
      for (final key in PushFailureKey.values) {
        await prefs.remove(key.storageKey);
      }
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
        decryptError: decryptError,
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

  /// `nse.decrypt_failed` 発生時に WebPushDecryptor / CryptoKit が投げた
  /// error の type + case 名（"WebPushError.invalidKeyId" /
  /// "CryptoKitError.authenticationFailure" 等）。NSE 由来でない経路では null。
  final String? decryptError;

  const PushFailureRecord({
    required this.code,
    required this.at,
    required this.count,
    this.host,
    this.encoding,
    this.elapsedMs,
    this.keychainStatus,
    this.triedPrefixes,
    this.decryptError,
  });
}
