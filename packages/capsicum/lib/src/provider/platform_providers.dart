import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/media_picker/media_picker.dart';
import '../platform/media_picker/media_picker_factory.dart';

/// プラットフォーム抽象層 (`lib/src/platform/`) の Riverpod 入口。
/// UI 層はこの provider 経由で実装を受け取り、`Platform.isXxx` を
/// 直接参照しない (CLAUDE.md デスクトップ対応 設計指針)。

/// メディア選択 ([MediaPicker])。iOS / Android / macOS は image_picker、
/// Linux / Windows は file_selector を使う。
final mediaPickerProvider = Provider<MediaPicker>((_) => createMediaPicker());
