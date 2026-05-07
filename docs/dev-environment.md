# 開発環境・検証端末

開発マシン・実機検証端末・Android エミュレータのセットアップに関するメモ。個人環境前提のため、他マシンに移行する際の参照用。

## 対応 OS

メインの開発ホストは **macOS**。Apple toolchain（Xcode / fastlane / 各種証明書 / `.p8` 鍵）と Android toolchain・Sentry dSYM アップロード環境がここに揃っており、リリースサイクルおよび iOS / Android / macOS 向けビルドはすべてこのマシンで行う。

v1.24（[CLAUDE.md](CLAUDE.md#デスクトップ対応) のデスクトップ対応 第3段階）以降は Linux / Windows を **補助機**として併用する。Flutter のデスクトップビルドは `flutter build linux` / `flutter build windows` ともクロスコンパイル不可で、配布パイプライン（[#423](https://github.com/pooza/capsicum/issues/423) / [#424](https://github.com/pooza/capsicum/issues/424)）と実機検証（[#425](https://github.com/pooza/capsicum/issues/425)）はそれぞれの OS でしか進められないため。補助機は OS 固有作業（Linux/Windows ビルド・配布物生成・実機検証）専用で、リリース判定・ストア公開・各種シークレット管理はメインの macOS に集約する。

## メイン (macOS) セットアップ

- `~/.config/capsicum/AuthKey_WLS8G4W44L.p8` に App Store Connect API Key を配置（Fastfile から参照）
- `~/.config/capsicum/google-play-service-account.json` に Google Play サービスアカウント JSON キーを配置
- `~/.config/capsicum/secrets.env` を Google Drive 上の実体（`/Volumes/extdata/gdrive/プライベート共有/Documents/b-shock/capsicum/secrets.env`）への symlink で配置（`SENTRY_DSN` / `RELAY_SECRET` を複数 PC で共有するため）
- Xcode → Settings → Accounts で Apple ID 追加 → Manage Certificates → Apple Distribution 証明書を作成
- `gem install fastlane`（rbenv の Ruby を使用）
- Android 署名鍵 `android/key.properties` を配置（git 管理外、手動配置）
- リポジトリルートの `.sentryclirc`（git 管理外）に dSYM アップロード用トークンを配置（`sentry_dart_plugin` が自動参照）
- `~/.sentryclirc` に Issue 読み取り用トークン（`event:read` / `event:write` / `project:read`）を配置

詳細なリリース手順は [store-release-guide.md](store-release-guide.md) を参照。

## 補助機（Linux / Windows）セットアップ

v1.24 以降のデスクトップ向け作業（[#423](https://github.com/pooza/capsicum/issues/423) / [#424](https://github.com/pooza/capsicum/issues/424) / [#425](https://github.com/pooza/capsicum/issues/425)）専用。Apple / Google Play 関連のシークレットや署名鍵は持ち込まない。

### 共通

- リポジトリは `~/repos/capsicum` にクローン（全端末共通の配置ルール）
- Flutter SDK（stable channel に固定）、Melos（`dart pub global activate melos`）、`gh` CLI
- `sentry-cli` を GitHub Releases から `~/.local/bin/sentry-cli`（Windows は `%USERPROFILE%\.local\bin\sentry-cli.exe`）に直接配置（MacPorts / Homebrew / scoop 等のパッケージマネージャ不使用）
- `~/.sentryclirc` に Issue 読み取り用トークンを配置（メインと同じ）
- Google Drive クライアント（Drive for desktop 等）をインストールし、`~/.config/capsicum/secrets.env` を Google Drive 上の実体への symlink で配置
- Claude Code の memory ディレクトリ（`~/.claude/projects/<project-key>/memory/`）も Google Drive 上の `claude-memory/` 実体への symlink で共有する。`<project-key>` は Claude Code 起動時に作業ディレクトリから自動生成されるため、起動後に確認してから symlink を張る

### Linux 固有

[#424](https://github.com/pooza/capsicum/issues/424) で実機検証して確定した system 依存:

```sh
sudo apt install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev libsecret-1-dev libwebkit2gtk-4.1-dev \
  libcurl4-openssl-dev default-jdk-headless \
  libfuse2t64 patchelf
```

- `libgtk-3-dev` / `libsecret-1-dev`: Flutter desktop と flutter_secure_storage 用
- `libwebkit2gtk-4.1-dev`: `flutter_web_auth_2` が transitive で引く `desktop_webview_window` の OAuth 用 WebView (#382 で OS デフォルトブラウザ方式に切り替えれば不要になる候補)
- `libcurl4-openssl-dev`: sentry-native の HTTP 送信
- `default-jdk-headless`: `sentry_flutter` が transitive で引く `jni` のヘッダ (ビルド時のみ。実行時は使われない)
- `libfuse2t64` / `patchelf`: AppImage 起動と linuxdeploy の依存解決

配布パイプライン作業時は追加で:

```sh
sudo apt install -y flatpak flatpak-builder
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.gnome.Platform//49 org.gnome.Sdk//49
```

`linuxdeploy` / `linuxdeploy-plugin-gtk.sh` / `appimagetool` は GitHub Releases から `~/.local/bin/` に直接配置（`sentry-cli` と同じ運用）。具体手順は [packaging/linux/appimage/README.md](../packaging/linux/appimage/README.md)。

Flathub アカウント（pooza 個人）は最初の submission ([packaging/linux/flathub/SUBMISSION.md](../packaging/linux/flathub/SUBMISSION.md)) で必要。

### Windows 固有

- Visual Studio 2022 Build Tools（"Desktop development with C++" workload）
- MSIX packaging tool（[#423](https://github.com/pooza/capsicum/issues/423) の MSIX 生成用）
- Microsoft Partner Center アカウント（Microsoft Store 登録用）

### 持ち込まないもの

- Apple toolchain（Xcode / fastlane / Apple Distribution 証明書 / `AuthKey_*.p8`）
- Android 署名鍵（`android/key.properties`）/ Google Play サービスアカウント JSON
- リポジトリルートの `.sentryclirc`（dSYM アップロード用、iOS/Android/macOS 専用）

リリース判定・ストア公開・iOS/Android/macOS の dSYM アップロードはすべてメインの macOS で行うため、補助機にこれらを置く必要はない。

## Sentry

- ダッシュボード: <https://b-shock-co-ltd.sentry.io/>
- プロジェクト: `capsicum`
- 有料プラン（安価なサブスクリプション）契約済み（2026-03-13）
- DSN は公開鍵相当（送信専用）なのでビルドへの埋め込みは問題なし
- 環境切り替え: `--dart-define=SENTRY_ENV=production`（デフォルト `debug`）
- dSYM / ProGuard マッピング自動アップロード: `sentry_dart_plugin` 導入済み。リポジトリルートの `.sentryclirc`（git 管理外）でトークン管理。環境変数 `SENTRY_AUTH_TOKEN` はプロジェクトごとのトークン使い分けのため使わない

### 活用戦略

ピンポイント方式（問題が起きた箇所・起きやすい箇所に `captureException` を仕込む）。現在の計装:

- `runZonedGuarded` で未処理例外を全捕捉
- ページネーション・WebSocket 等の既知問題箇所にピンポイント送信

次の拡張タイミング: ストア公開後ユーザーが増えた段階でパフォーマンスモニタリング導入を検討。

### Issue 読み取り用トークン

リポジトリ直下の `.sentryclirc` は dSYM アップロード用の `org:ci` スコープのみで、Issue 読み取り不可。進捗同期時に `sentry-cli issues list` を使う際は `~/.sentryclirc`（広スコープ、`project:read` あり）のトークンを `--auth-token` フラグで明示指定する（`SENTRY_AUTH_TOKEN` 環境変数はプロジェクトごとのトークン使い分けを壊すため使わない）。詳細は [sync-procedure.md](sync-procedure.md) の同期手順を参照。

## iOS 実機環境

- デバイス: iPhone 13 mini「金星魔術郷」(iOS 26.2.1)
- UDID: `00008110-0019442101B9801E`
- Parallels Desktop が USB デバイスを横取りするため、実機接続時は Parallels を終了させること
- iOS アップデート後にデベロッパモードがリセットされることがある → 設定 → プライバシーとセキュリティ → デベロッパモード で再有効化

## Android エミュレータ環境

- `ANDROID_SDK_ROOT`: `~/Library/Android/sdk`
- `JAVA_HOME`: `/Applications/Android Studio.app/Contents/jbr/Contents/Home`
- エミュレータ起動: `$ANDROID_SDK_ROOT/emulator/emulator -avd Medium_Phone_API_35`
- AVD: `Medium_Phone_API_35` (API 35, arm64)

### エミュレータで既知の問題

- カスタムスキーム `capsicum://oauth` のリダイレクトが Android エミュレータで動作しない（OOB 方式で代用中）。[tech-notes.md](tech-notes.md) の認証フロー節も参照

## Android 検証端末

| 端末 | 用途 |
| --- | --- |
| iPhone 13 mini | 日常使用 + iOS テスト |
| Pixel 8 | 日常使用。検証兼用は避ける方針 |
| Pixel 6a（SIM なし） | Android 検証専用端末 |
