import 'package:flutter/foundation.dart';

import '../util/shared_preferences_cache.dart';

/// プッシュ通知をオフにしたアカウント (#1408)。
///
/// 値は [AccountKey.toStorageKey] の集合。**端末ごと**の設定（プッシュの登録は
/// 端末ごとなので、スマホでは受けるがタブレットでは受けない、が成り立つ）。
/// バックアップでは端末固有の側（`deviceLocalKeys`）。
///
/// ⚠⚠ **オフにしても relay の行は消さない。**登録の処理は relay への登録までは
/// 続け、SNS 側の購読だけをしない（`PushRegistrationService._registerAccountImpl`）。
/// relay は「同じ端末にプリセットの行があるか」で無償の特例を決めている
/// （relay#82）ので、プリセットのアカウントをオフにしたとき行まで消すと、
/// 端末のトークンが変わった回の掃除のあとで外部のアカウントが有償側に倒れる
/// （2026-11-22 pooza 判断・案 A）。
class PushDisabledAccounts {
  PushDisabledAccounts._();

  /// ⚠ `settings_backup_coverage_test.dart` がこの形で拾う。名前を変えない。
  static const prefsKey = 'push_disabled_accounts';

  /// [storageKey] のプッシュ通知がオフか。読めなければ false（＝今どおり受ける）。
  static bool isDisabled(String storageKey) {
    try {
      return sharedPrefsOrThrow.getStringList(prefsKey)?.contains(storageKey) ??
          false;
    } catch (e) {
      debugPrint('capsicum: push.disabled: read failed: ${e.runtimeType}');
      return false;
    }
  }

  static Future<void> setDisabled(String storageKey, bool disabled) async {
    final current = {...?sharedPrefsOrThrow.getStringList(prefsKey)};
    final changed = disabled
        ? current.add(storageKey)
        : current.remove(storageKey);
    if (!changed) return;
    await (current.isEmpty
        ? sharedPrefsOrThrow.remove(prefsKey)
        : sharedPrefsOrThrow.setStringList(prefsKey, [...current]));
  }
}
