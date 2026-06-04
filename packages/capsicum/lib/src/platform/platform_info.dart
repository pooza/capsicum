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

/// OAuth ログイン画面で「ブラウザから戻れないとき」の手動コード入力カードを
/// 出すべきプラットフォームか（#556）。
///
/// Android は Custom Tabs からアプリへ自動復帰できず、認証後にタイムライン等へ
/// 遷移してしまうケースがあるため、手動コード貼り付け導線を案内する必要がある。
/// UI 層に `Platform.isAndroid` を直書きしない（CLAUDE.md デスクトップ対応の
/// 設計指針）ため、機能名で公開する feature flag。
bool get requiresManualCodeFallbackCard => !kIsWeb && Platform.isAndroid;
