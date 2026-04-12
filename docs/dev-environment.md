# 開発環境・検証端末

開発マシン・実機検証端末・Android エミュレータのセットアップに関するメモ。個人環境前提のため、他マシンに移行する際の参照用。

## 対応 OS

開発は macOS のみで行う。Windows は開発ホストとしての対応対象外。

ここでの「Windows 対象外」は **開発ホスト**（ビルドや実機検証を行うマシン）の話であり、**ターゲットプラットフォームとしての Windows 対応**は別の議論。後者は [CLAUDE.md](CLAUDE.md#長期構想-デスクトップ対応) の「長期構想: デスクトップ対応」で段階的に進める長期目標として位置づけている。

## 各マシン共通セットアップ

- `~/.config/capsicum/AuthKey_WLS8G4W44L.p8` に App Store Connect API Key を配置（Fastfile から参照）
- `~/.config/capsicum/google-play-service-account.json` に Google Play サービスアカウント JSON キーを配置
- Xcode → Settings → Accounts で Apple ID 追加 → Manage Certificates → Apple Distribution 証明書を作成
- `gem install fastlane`（rbenv の Ruby を使用）
- Android 署名鍵 `android/key.properties` を配置（git 管理外、手動配置）
- リポジトリルートの `.sentryclirc`（git 管理外）に dSYM アップロード用トークンを配置（`sentry_dart_plugin` が自動参照）

詳細なリリース手順は [store-release-guide.md](store-release-guide.md) を参照。

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

リポジトリ直下の `.sentryclirc` は dSYM アップロード用の `org:ci` スコープのみで、Issue 読み取り不可。進捗同期時に `sentry-cli issues list` を使う際は `~/.sentryclirc`（広スコープ、`project:read` あり）のトークンを `SENTRY_AUTH_TOKEN` で明示指定する。詳細は [CLAUDE.md](CLAUDE.md) の同期手順節を参照。

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
