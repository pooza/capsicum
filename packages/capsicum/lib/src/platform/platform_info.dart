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

/// 常駐モード (#752) の常駐先の OS 別呼称。macOS は「メニューバー」
/// （NSStatusItem）、Windows / Linux は「トレイ」。設定画面の説明文を OS に
/// 合わせて出し分けるために機能名で公開する（UI 層に `Platform.isX` を直書き
/// しない設計指針・#650）。
String get residentTargetLabel =>
    !kIsWeb && Platform.isMacOS ? 'メニューバー' : 'トレイ';

/// メディアビューアから OS ファイラー（Finder / Explorer）への drag-out
/// （#645）に対応するプラットフォームか。super_drag_and_drop の virtual file
/// （遅延ファイル生成）は macOS / Windows のみ対応で、Linux (GTK) は drag-source
/// として非対応のため除外する（Linux は別 issue）。UI 層に `Platform.isX` を
/// 直書きしない設計指針に従い機能名で公開する。
bool get supportsMediaDragOut =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows);

/// OAuth ログイン画面で「ブラウザから戻れないとき」の手動コード入力カードを
/// 出すべきプラットフォームか（#556）。
///
/// Android は Custom Tabs からアプリへ自動復帰できず、認証後にタイムライン等へ
/// 遷移してしまうケースがあるため、手動コード貼り付け導線を案内する必要がある。
/// UI 層に `Platform.isAndroid` を直書きしない（CLAUDE.md デスクトップ対応の
/// 設計指針）ため、機能名で公開する feature flag。
bool get requiresManualCodeFallbackCard => !kIsWeb && Platform.isAndroid;
