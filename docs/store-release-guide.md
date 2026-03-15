# ストアリリース手順書

## 1. 初回セットアップ（一度だけ）

### 1.1 Google Play Developer アカウント

- [ ] [Google Play Console](https://play.google.com/console) でアカウント登録（$25）
- [ ] アプリの新規作成（パッケージ名: `net.shrieker.capsicum`）

> **注意:** iOS の Bundle ID は `jp.co.b-shock.capsicum`（Apple Developer Team の制約による）。
> Android の applicationId は `net.shrieker.capsicum` のまま。通常は一致させるが、
> Android にはハイフンが使えない制約もあり、本アプリでは意図的に異なる値としている。

### 1.2 Android 署名鍵

- [x] リリース用 keystore の生成（`capsicum-release.jks`）
- [x] `android/key.properties` の作成（git 管理外）
- [x] `android/app/build.gradle.kts` に署名設定を追加

### 1.3 iOS 署名

- [x] App Store Connect でアプリの新規作成（Bundle ID: `jp.co.b-shock.capsicum`）
- [x] 配布用証明書（Distribution Certificate）の確認 — Automatic Signing で自動管理
- [x] App Store 用 Provisioning Profile の作成 — Automatic Signing で自動管理
- [x] PrivacyInfo.xcprivacy の追加
- [x] ITSAppUsesNonExemptEncryption の設定
- [x] App Store Connect API Key の配置

> **各マシン共通の前提:**
> App Store Connect API Key（`.p8`）を `~/.config/capsicum/AuthKey_WLS8G4W44L.p8` に配置すること。
> Fastlane の Fastfile はこのパスを参照する。
> 配布用証明書（Apple Distribution）は Xcode → Settings → Accounts → Manage Certificates で追加する。

### 1.4 プライバシーポリシー

- [x] プライバシーポリシーの作成（`docs/privacy-policy.md`）
- [x] `capsicum.shrieker.net/privacy-policy` で公開
- [x] URL をストアの掲載情報に設定

### 1.5 コンテンツレーティング

- [x] Google Play: IARC 質問回答
- [x] App Store: 年齢区分の設定（16+）
- SNS クライアントのため「ユーザー生成コンテンツ」に該当

## 2. ストア掲載情報

### 2.1 共通で必要なもの

- [x] アプリ名: capsicum
- [x] 短い説明文（80 文字以内）— `store-listing.md` に記載
- [x] 詳細な説明文 — `store-listing.md` に記載
- [x] カテゴリ: ソーシャルネットワーキング
- [x] プライバシーポリシー URL

### 2.2 Google Play 固有

- [x] フィーチャーグラフィック（1024x500）
- [x] スクリーンショット（最低 2 枚、推奨 4-8 枚）
- [x] アイコン（512x512）— Adaptive Icon 設定済み

### 2.3 App Store 固有

- [x] スクリーンショット（6.7 インチ — 1284×2778 にリサイズして登録済み）
- [x] アイコン（1024x1024）— 設定済み
- [x] キーワード（100 文字以内）— `store-listing.md` に記載
- [x] サポート URL — `https://github.com/pooza/capsicum/issues`

## 3. Fastlane セットアップ

### 3.1 インストール

```bash
gem install fastlane
```

### 3.2 Android（`android/fastlane/Fastfile`）

ビルドは事前に行い、Fastlane は Play Store へのアップロードのみを担当する（iOS と同じ方式）。

```ruby
default_platform(:android)

json_key_path = File.expand_path('~/.config/capsicum/google-play-service-account.json')

platform :android do
  desc "Deploy to Google Play internal testing"
  lane :internal do
    upload_to_play_store(
      track: 'internal',
      aab: '../build/app/outputs/bundle/release/app-release.aab',
      json_key: json_key_path,
    )
  end

  desc "Promote internal to production"
  lane :release do
    upload_to_play_store(
      track: 'internal',
      track_promote_to: 'production',
      json_key: json_key_path,
    )
  end
end
```

> **各マシン共通の前提:**
> Google Play サービスアカウントの JSON キーを `~/.config/capsicum/google-play-service-account.json` に配置すること。
> キーは Google Cloud Console のサービスアカウント管理画面からダウンロードし、Play Console の「ユーザーと権限」でそのサービスアカウントに capsicum アプリのリリース権限を付与しておく。

### 3.3 iOS（`ios/fastlane/Fastfile`）

ビルドは事前に行い、Fastlane は TestFlight / App Store へのアップロードのみを担当する。

```ruby
default_platform(:ios)

platform :ios do
  desc "Deploy to TestFlight"
  lane :beta do
    upload_to_testflight(
      ipa: '../build/ios/ipa/capsicum.ipa',
    )
  end

  desc "Submit to App Store"
  lane :release do
    upload_to_app_store(
      ipa: '../build/ios/ipa/capsicum.ipa',
      submit_for_review: true,
    )
  end
end
```

## 4. リリース手順（毎回）

### 4.1 バージョン更新・依存関係の更新

```bash
# pubspec.yaml の version を更新（例: 1.0.0+1 → 1.0.1+2）
# 注意: ビルド番号（+N）は一度ストアにアップロードすると、リリースを破棄しても再利用不可。
# 上げ直す場合は必ずビルド番号をインクリメントすること。

# 依存パッケージを最新互換バージョンに更新（リリースのタイミングで実施）
cd packages/capsicum
flutter pub upgrade

# メジャーバージョンアップも含める場合（pubspec.yaml の制約も更新される）
flutter pub upgrade --major-versions
```

### 4.2 ビルド + アップロード

```bash
cd packages/capsicum

# Sentry DSN（全ビルドで常に指定する）
SENTRY_DSN="https://a4789a0cce4143a06e1cb643ba8ac7ab@o4511026200117248.ingest.us.sentry.io/4511026210471936"

# iOS: ビルド → TestFlight アップロード
flutter build ipa --release \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=SENTRY_ENV=production
cd ios && fastlane beta && cd ..

# Android: ビルド → Play Store 内部テストトラックにアップロード
flutter build appbundle --release \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=SENTRY_ENV=production
cd android && fastlane internal && cd ..
```

### 4.3 ストアでの確認

- **Google Play**: 内部テストトラックで確認 → `cd android && fastlane release` で製品版に昇格
- **App Store**: TestFlight でテスト → `cd ios && fastlane release` で審査提出
