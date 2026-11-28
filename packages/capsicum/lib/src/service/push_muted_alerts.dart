import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/shared_preferences_cache.dart';

/// アカウントごとに、プッシュ通知で受け取らない通知の分類 (#1411)。
///
/// 値は `{storageKey: [分類の名前…]}` の JSON。**端末ごと**の設定（#1408 の
/// [PushDisabledAccounts] と同じ理由・プッシュの登録は端末ごと）。バックアップでは
/// 端末固有の側（`deviceLocalKeys`）。
///
/// ⚠ 効くのはサーバー側で絞れるアカウントだけ
/// （[PushSubscriptionSupport.supportsPushAlertFilter]）。
class PushMutedAlerts {
  PushMutedAlerts._();

  /// ⚠ `settings_backup_coverage_test.dart` がこの形で拾う。名前を変えない。
  static const prefsKey = 'push_muted_alert_categories';

  static Map<String, List<String>> _decode(String? raw) {
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return {
      for (final e in decoded.entries)
        if (e.key is String && e.value is List)
          e.key as String: [
            for (final v in e.value as List)
              if (v is String) v,
          ],
    };
  }

  static Map<String, List<String>> _readAll() =>
      _decode(sharedPrefsOrThrow.getString(prefsKey));

  static Set<PushAlertCategory> _categoriesOf(List<String> names) => {
    for (final c in PushAlertCategory.values)
      if (names.contains(c.name)) c,
  };

  /// [storageKey] で受け取らない分類。読めなければ空（＝今どおり全部受ける）。
  static Set<PushAlertCategory> mutedFor(String storageKey) {
    try {
      return _categoriesOf(_readAll()[storageKey] ?? const []);
    } catch (e) {
      debugPrint('capsicum: push.muted: read failed: ${e.runtimeType}');
      return const {};
    }
  }

  /// [mutedFor] の、バックグラウンドの isolate から読める版（プッシュの引き直し・
  /// #1426）。
  ///
  /// ⚠ バックグラウンドの isolate では main() の pre-warm（[sharedPrefsOrThrow]）が
  /// 無く、`SharedPreferences` の写しも isolate ごとなので、`reload` してから読む
  /// （本体で変えた直後の値を拾う）。読めなければ空。
  static Future<Set<PushAlertCategory>> readMutedFor(String storageKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return _categoriesOf(
        _decode(prefs.getString(prefsKey))[storageKey] ?? const [],
      );
    } catch (e) {
      debugPrint('capsicum: push.muted: read failed: ${e.runtimeType}');
      return const {};
    }
  }

  static Future<void> setMuted(
    String storageKey,
    Set<PushAlertCategory> muted,
  ) async {
    final all = _readAll();
    if (muted.isEmpty) {
      if (all.remove(storageKey) == null) return;
    } else {
      all[storageKey] = [for (final c in muted) c.name]..sort();
    }
    await (all.isEmpty
        ? sharedPrefsOrThrow.remove(prefsKey)
        : sharedPrefsOrThrow.setString(prefsKey, jsonEncode(all)));
  }

  /// アカウントの削除で捨てる。⚠ **投げない**（削除の途中で止めない）。
  static Future<void> forget(String storageKey) async {
    try {
      await setMuted(storageKey, const {});
    } catch (e) {
      debugPrint('capsicum: push.muted: forget failed: ${e.runtimeType}');
    }
  }
}
