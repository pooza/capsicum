import 'dart:io' show Platform;

import 'file_selector_media_picker.dart';
import 'image_picker_media_picker.dart';
import 'media_picker.dart';

/// プラットフォームに応じた [MediaPicker] 実装を生成する。
///
/// [Platform.isXxx] を参照する箇所は `lib/src/platform/` 配下に閉じ込める
/// (CLAUDE.md デスクトップ対応 設計指針)。UI 層は Riverpod provider 経由で
/// 抽象を受け取る。
MediaPicker createMediaPicker() {
  if (Platform.isLinux || Platform.isWindows) {
    return FileSelectorMediaPicker();
  }
  return ImagePickerMediaPicker();
}
