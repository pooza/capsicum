# ストアリリース手順書

## 1. 初回セットアップ（一度だけ）

### 1.1 Google Play Developer アカウント

- [ ] [Google Play Console](https://play.google.com/console) でアカウント登録（$25）
- [ ] アプリの新規作成（パッケージ名: `net.shrieker.capsicum`）

### 1.2 Android 署名鍵

- [ ] アップロード鍵の生成

```bash
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

- [ ] `android/key.properties` の作成（git 管理外）

```properties
storePassword=<password>
keyPassword=<password>
keyAlias=upload
storeFile=<path>/upload-keystore.jks
```

- [ ] `android/app/build.gradle` に署名設定を追加

### 1.3 iOS 署名

- [ ] App Store Connect でアプリの新規作成（Bundle ID: `net.shrieker.capsicum`）
- [ ] 配布用証明書（Distribution Certificate）の確認
- [ ] App Store 用 Provisioning Profile の作成

### 1.4 プライバシーポリシー

- [ ] プライバシーポリシーのページを作成・公開（GitHub Pages 等）
  - 収集するデータ: なし（サーバーとの直接通信のみ、アプリ側でデータ収集しない）
  - 認証情報の保存方法: デバイスのセキュアストレージ
- [ ] URL をストアの掲載情報に設定

### 1.5 コンテンツレーティング

- [ ] Google Play: IARC 質問回答
- [ ] App Store: 年齢区分の設定
- SNS クライアントのため「ユーザー生成コンテンツ」に該当

## 2. ストア掲載情報

### 2.1 共通で必要なもの

- [ ] アプリ名: capsicum
- [ ] 短い説明文（80 文字以内）
- [ ] 詳細な説明文
- [ ] カテゴリ: ソーシャルネットワーキング
- [ ] プライバシーポリシー URL

### 2.2 Google Play 固有

- [ ] フィーチャーグラフィック（1024x500）
- [ ] スクリーンショット（最低 2 枚、推奨 4-8 枚）
- [ ] アイコン（512x512）

### 2.3 App Store 固有

- [ ] スクリーンショット（6.7 インチ、6.5 インチ、5.5 インチ）
- [ ] アイコン（1024x1024）
- [ ] キーワード（100 文字以内）
- [ ] サポート URL

## 3. Fastlane セットアップ

### 3.1 インストール

```bash
gem install fastlane
```

### 3.2 Android（`android/fastlane/Fastfile`）

```ruby
default_platform(:android)

platform :android do
  desc "Deploy to Google Play internal testing"
  lane :internal do
    sh "flutter build appbundle --release"
    upload_to_play_store(
      track: 'internal',
      aab: '../build/app/outputs/bundle/release/app-release.aab',
    )
  end

  desc "Promote internal to production"
  lane :release do
    upload_to_play_store(
      track: 'internal',
      track_promote_to: 'production',
    )
  end
end
```

### 3.3 iOS（`ios/fastlane/Fastfile`）

```ruby
default_platform(:ios)

platform :ios do
  desc "Deploy to TestFlight"
  lane :beta do
    sh "flutter build ipa --release"
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

### 4.1 バージョン更新

```bash
# pubspec.yaml の version を更新（例: 1.0.0+1 → 1.0.1+2）
```

### 4.2 ビルド + アップロード

```bash
# Android
cd android && fastlane internal

# iOS
cd ios && fastlane beta
```

### 4.3 ストアでの確認

- Google Play Console で内部テストを確認 → 製品版に昇格
- TestFlight でテスト → App Store Connect で審査提出
