/// プラットフォーム別のアプリデータパス解決を 1 箇所に集約する薄いユーティリティ。
///
/// Dart 側は path_provider の `getApplicationSupportDirectory()` に委譲する
/// （Linux は `XDG_DATA_HOME`、Windows MSIX は
/// `%LOCALAPPDATA%\Packages\<PFN>\LocalCache\...` をそれぞれ解決する）。
/// AppImage の AppRun（bash）側は
/// `${XDG_DATA_HOME:-$HOME/.local/share}/capsicum/logs` を独自に解決して
/// おり（[packaging/linux/appimage/build.sh]）、両者が同じ
/// `~/.local/share/capsicum/` 階層に着地する前提に依存する。パス解決の
/// 知識が散らないよう Dart 側はここを唯一の参照点にする（#522）。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// sentry-native の crash database を置くパス（Linux / Windows のみ）。
///
/// 非対応 OS（macOS / iOS / Android）では `null` を返し、呼び出し側は
/// sentry-native の既定動作（CWD 直下に `.sentry-native/` を作成）に委ねる。
/// path_provider が失敗した場合は例外を送出するため、起動経路を止めない
/// よう呼び出し側で握りつぶすこと（#496）。
Future<String?> resolveSentryNativeDatabasePath() async {
  if (!Platform.isLinux && !Platform.isWindows) return null;
  final supportDir = await getApplicationSupportDirectory();
  return '${supportDir.path}/.sentry-native';
}
