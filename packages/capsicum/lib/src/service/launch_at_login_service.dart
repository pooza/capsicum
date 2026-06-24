import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import '../constants.dart';

/// デスクトップのログイン時起動 (#751)。OS のログイン項目 / 自動起動に
/// 本アプリを登録 / 解除する。`launchAtLoginProvider` の値変化を受けて
/// OS 状態を張り替える（pref が真実源・OS は従属）。
///
/// v1.40 は **Windows のみ有効化**（[isSupported]）。macOS（ログイン項目 /
/// MAS は SMAppService）・Linux（~/.config/autostart）の検証と有効化は
/// #757 (v1.42) で行い、[isSupported] を広げる。
class LaunchAtLoginService {
  static bool _setup = false;

  /// ログイン時起動を UI に露出する OS。コードは launch_at_startup で全
  /// デスクトップ対応だが、v1.40 では検証済みの Windows のみ有効化する。
  static bool get isSupported => Platform.isWindows;

  static void _ensureSetup() {
    if (_setup) return;
    launchAtStartup.setup(
      appName: AppConstants.appName,
      appPath: Platform.resolvedExecutable,
      // MSIX (Microsoft Store / 自己署名直配) では packageName 指定で
      // StartupTask 経路になる。非 MSIX の直 exe 起動ではレジストリ Run キー
      // 経路に倒れる（isRunningInMsix が false を返すため）。
      packageName: WindowsIdentifiers.appUserModelId,
    );
    _setup = true;
  }

  /// ログイン時起動の有効/無効を OS に適用する。`launchAtLoginProvider` の
  /// 値変化から呼ぶ。冪等。
  static Future<void> setEnabled(bool value) async {
    if (!isSupported) return;
    _ensureSetup();
    try {
      if (value) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (e) {
      debugPrint('capsicum: launch_at_login: setEnabled($value) failed: $e');
    }
  }
}
