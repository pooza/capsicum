import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

/// デスクトップ 3 OS（macOS / Linux / Windows）かどうか。
///
/// `Platform.isMacOS || Platform.isWindows || Platform.isLinux` の OR が
/// 各所に散っていたのを 1 箇所に集約した（#650）。capsicum は web を配布
/// 対象にしていないが、`Platform` は web で例外を投げるため `!kIsWeb` で
/// 防御する（media_viewer の既存実装に合わせた最も安全側の定義）。
bool get isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// ファイルの保存先を OS の保存ダイアログで選べるプラットフォームか
/// (#972)。`file_selector` の `getSaveLocation` が実装されているのは
/// デスクトップ 3 OS だけで、`file_selector_ios` / `file_selector_android` は
/// どちらも `openFile` しか持たず、保存側は platform interface の既定に落ちて
/// `UnimplementedError` を投げる。false のプラットフォームは OS の共有シート
/// （`share_plus`）へ渡して保存先をユーザーに委ねる。
///
/// 読み込み側（`openFile`）は 5 OS すべてで実装されているので、この分岐は
/// **書き出しにしか要らない**。UI 層に `Platform.isX` を直書きしない設計指針
/// （#650）に従い機能名で公開する。
bool get supportsFileSaveDialog => isDesktop;

/// ファイル選択の絞り込みを Uniform Type Identifier で指定するプラットフォーム
/// か (#972)。**iOS だけ** `XTypeGroup.uniformTypeIdentifiers` を要求し、空だと
/// `openFile` が `ArgumentError` を投げる（拡張子だけでは選べない）。
///
/// 他 OS は `extensions` / `mimeTypes` を見て UTI を無視するが、macOS だけは
/// **3 フィールドを和で解釈する**。そのため iOS 向けの広い UTI を常時載せると
/// macOS の絞り込みまで緩む。分岐が要るのはこのため。
bool get fileTypeFilterNeedsUti => !kIsWeb && Platform.isIOS;

/// カラー絵文字 fallback (#861) が意味を持ち、その調整トグルを設定に出す
/// プラットフォームか。Linux のみ true。Linux では `Noto Color Emoji` を
/// fontFamilyFallback に足すと同フォントが ASCII 数字 `0-9` `#` `*`・空白まで
/// 横取りして半角数字の幅が崩れる (#869)。#871 では当該コードポイントだけを
/// 収めた極小フォント (Capsicum Latin Fallback) を前段に置いて両立させたが、
/// 横取りはホストの fontconfig 挙動依存で環境差があるため、効かない環境向けの
/// 保険トグル ([colorEmojiFallbackProvider]) をこのフラグで Linux 限定表示する。
/// 他 OS は OS 側の絵文字解決が既に正しく実質 no-op のためトグルを出さない。
/// UI 層に `Platform.isX` を直書きしない設計指針 (#650) に従い機能名で公開する。
bool get colorEmojiFallbackConfigurable => !kIsWeb && Platform.isLinux;

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
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

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

/// Keychain の accessibility / accessGroup という概念を持つプラットフォームか
/// (#1085)。Apple 系（iOS / macOS）だけ true。
///
/// ⚠⚠ **起動経路で secure storage を叩く理由になるのはここだけ。**
/// accessibility の焼き直し migration（#392 / #643）は「フラグを立てるため」に
/// 全プラットフォームで走っていたが、Android (EncryptedSharedPreferences) /
/// Linux (libsecret) / Windows (DPAPI) には焼き直すものが無い。**Linux では
/// Secret Service が死んでいると `readAll` が返らず、`runApp()` の手前で
/// 止まって真っ黒なウインドウになる**（#1085 の症状）。
///
/// UI 層に `Platform.isX` を直書きしない設計指針 (#650) と同じ理由で、
/// storage 層にも直書きせず機能名で公開する。
bool get usesKeychainAccessibility =>
    debugKeychainAccessibilityOverride ??
    (!kIsWeb && (Platform.isIOS || Platform.isMacOS));

/// テスト用の差し替え口 (#1085)。
///
/// ⚠ **これが無いと、Apple 系でしか動かない migration の検査が CI（Linux）で
/// 素通りする。**実際にこの seam を入れる前は、手元（macOS）で緑・CI で赤に
/// なった。**プラットフォーム分岐を入れたら、分岐の両側をテストから踏めるように
/// すること。**
@visibleForTesting
bool? debugKeychainAccessibilityOverride;
