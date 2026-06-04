import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// デスクトップ 3 OS（macOS / Linux / Windows）かどうか。
///
/// `Platform.isMacOS || Platform.isWindows || Platform.isLinux` の OR が
/// 各所に散っていたのを 1 箇所に集約した（#650）。capsicum は web を配布
/// 対象にしていないが、`Platform` は web で例外を投げるため `!kIsWeb` で
/// 防御する（media_viewer の既存実装に合わせた最も安全側の定義）。
bool get isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
