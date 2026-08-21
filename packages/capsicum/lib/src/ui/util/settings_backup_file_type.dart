import 'package:file_selector/file_selector.dart';

/// 設定バックアップのファイル選択（`openFile` / `getSaveLocation`）に渡す型
/// グループ (#972)。
///
/// **要求するフィールドがプラットフォームで違う**ので、1 つの定数では足りない。
///
/// | OS | 必要なもの | UTI の扱い |
/// |----|-----------|-----------|
/// | iOS | `uniformTypeIdentifiers`（空だと `ArgumentError`） | これしか見ない |
/// | Android / Linux | `extensions` or `mimeTypes` | 無視 |
/// | Windows | `extensions` | 無視 |
/// | macOS | いずれか 1 つ以上 | **3 つを和で足す** |
///
/// [needsUti] を立てるのは iOS だけ（`fileTypeFilterNeedsUti`）。macOS が 3 つを
/// 和で解釈するため、iOS 向けの広い UTI を常時載せると **macOS のダイアログの
/// 絞り込みまで緩む**。分岐が要るのはこのため。
XTypeGroup settingsBackupTypeGroup({required bool needsUti}) => XTypeGroup(
  label: '設定のバックアップ',
  extensions: const ['yaml', 'yml'],
  mimeTypes: const ['application/x-yaml', 'text/yaml'],
  // `public.yaml` は iOS 16 以降にしか無く、capsicum の下限は v1.57 以降 iOS 15。
  // 15 では `.yaml` が dyn.* 扱いになり `public.text` にも適合しないため、
  // 取りこぼさないよう `public.data` にする。設定バックアップでないファイルを
  // 選んでも SettingsBackupFormatException で弾かれるので、緩くても実害はない。
  uniformTypeIdentifiers: needsUti ? const ['public.data'] : null,
);
