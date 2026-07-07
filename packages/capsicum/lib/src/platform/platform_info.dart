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

/// メディアビューアから OS ファイラー（Finder / Explorer / Nautilus）への
/// drag-out（#645 / #776）に対応するプラットフォームか。デスクトップ 3 OS で
/// 対応する。ただし渡し方は OS で分かれる: macOS / Windows は
/// super_drag_and_drop の virtual file（遅延ファイル生成）、Linux (GTK) は
/// virtual file 非対応のため drag 開始時に temp へ実ファイルを書き出して file
/// URI を渡す（#776）。この差は package の `DragItem.virtualFileSupported`
/// capability で分岐し、UI 層に `Platform.isX` は直書きしない。
bool get supportsMediaDragOut =>
    !kIsWeb &&
    (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// OAuth の redirect を localhost ループバックで受けるプラットフォームか
/// (#276 / #654)。デスクトップ 3 OS と Android は、ブラウザ / Custom Tab が
/// custom scheme をアプリへ確実に引き渡せない（flutter_web_auth_2 #187 同型）
/// ため loopback で受ける。iOS は ASWebAuthenticationSession で custom scheme が
/// 確実に戻るため対象外。UI 層に `Platform.isX` を直書きしない設計指針
/// （#650・docs/CLAUDE.md）に従い機能名で公開する。
bool get usesLoopbackOAuthCallback =>
    isDesktop || (!kIsWeb && Platform.isAndroid);

/// loopback OAuth の受け口を、flutter_web_auth_2 の server impl ではなく
/// **自前の localhost HTTP サーバ**で立てるプラットフォームか (#276 / #654)。
/// macOS は fwa2 に localhost server impl が無く、Android は Custom Tab が
/// redirect を bounce するため、両者とも自前サーバで受ける。Linux / Windows は
/// fwa2 の server impl が `http://localhost:{port}` を直接受ける。
bool get usesSelfHostedOAuthLoopbackServer =>
    !kIsWeb && (Platform.isMacOS || Platform.isAndroid);

/// loopback callback ページから、コード受領後にアプリを前面へ戻す遷移
/// （androidOAuthReturnUrl）が必要なプラットフォームか (#276)。Android は
/// システムブラウザからアプリへ自動復帰しないため専用の callback HTML を返す。
bool get oauthCallbackNeedsAppReturn => !kIsWeb && Platform.isAndroid;

/// 既存アカウントの account-scoped cached client を OAuth に再利用してよいか
/// (#276)。Android の account-scoped client は登録時の redirect_uri を保持せず、
/// custom scheme → localhost 移行後に再利用すると invalid_redirect_uri で
/// loopback がハングするため、Android では再利用しない（host 保存 or fresh 登録
/// に委ねる）。他プラットフォームは従来どおり再利用してよい。
bool get canReuseAccountScopedOAuthClient => kIsWeb || !Platform.isAndroid;
