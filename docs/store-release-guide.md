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

### 1.4 macOS 署名 / Universal Purchase（v1.21 で初回セットアップ）

macOS ネイティブビルドは iOS と同じ Bundle ID `jp.co.b-shock.capsicum` を Universal Purchase で紐付け、AppStore Connect 上は同一 App レコードで管理する方針。配布は **Mac App Store 一本**（.dmg / Developer ID 配布は採用しない — [release-pipeline.md](release-pipeline.md) 参照）。

- [ ] Apple Developer ポータルで **macOS App ID** を新規作成
  - Bundle ID: `jp.co.b-shock.capsicum`（iOS と同一文字列。プラットフォームが違うため衝突しない）
  - Capabilities: **App Sandbox**（Release entitlements で必須）／ **Push Notifications**（capsicum-relay 経由で利用）
- [ ] AppStore Connect の既存 iOS app `capsicum` レコードで **「Add Mac App Version」** を実行し、上記 macOS App ID と紐付け（Universal Purchase 化）
  - ⚠️ Universal Purchase の紐付けは **後から外せない**。Bundle ID と App 名はこの時点で確定させる
- [ ] **macOS App Development Profile** と **Mac App Store Provisioning Profile** を作成 — Automatic Signing で自動管理
- [ ] **3rd Party Mac Developer Installer** 証明書を Apple Developer ポータルから取得し、ビルドマシンの Keychain に登録
  - `.pkg` の installer 署名に必須。Apple Distribution（アプリ署名）とは別証明書で、Xcode の Automatic 管理対象外のため手動で配置する
- [ ] Xcode で `packages/capsicum/macos/Runner.xcodeproj` を開き、Runner / RunnerTests ターゲットの `DEVELOPMENT_TEAM` を `Y27AK8VF85` に設定（iOS と同一 Team）
- [ ] Mac App Store 用スクリーンショット（1280×800 / 1440×900 / 2560×1600 のいずれか）を用意

> **APNs キーの共用:**
> iOS で使用している APNs Auth Key（`AuthKey_WLS8G4W44L.p8`）は macOS でもそのまま使える。`capsicum-relay` 側の APNs 接続も Bundle ID `jp.co.b-shock.capsicum` 単一で iOS / macOS 両プラットフォームを処理する。
>
> **Sandbox と flutter_secure_storage:**
> Debug entitlements では `app-sandbox=false` で運用している（ad-hoc 署名 + sandbox 有効では `errSecMissingEntitlement (-34018)` で flutter_secure_storage が動かないため）。development 署名（Apple Developer Team 紐付け済み）が通れば Debug でも sandbox を有効化できる見込み。Release entitlements は常に sandbox 有効。

### 1.5 プライバシーポリシー

- [x] プライバシーポリシーの作成（`docs/privacy-policy.md`）
- [x] `capsicum.shrieker.net/privacy-policy` で公開
- [x] URL をストアの掲載情報に設定

### 1.6 コンテンツレーティング

- [x] Google Play: IARC 質問回答
- [x] App Store: 年齢区分の設定（16+）
- SNS クライアントのため「ユーザー生成コンテンツ」に該当

### 1.7 シークレット環境変数（一度だけセットアップ）

ビルドに必要な `SENTRY_DSN` / `RELAY_SECRET` を `~/.config/capsicum/secrets.env` に保存し、リリースのたびに `source` して読み込む運用にする。リリース手順で env を毎回手打ちする煩わしさを減らし、`+50` で踏んだ「コマンドライン圧縮で `$VAR` が空展開」事故も予防できる。

```bash
cat > ~/.config/capsicum/secrets.env <<'EOF'
export SENTRY_DSN="https://a4789a0cce4143a06e1cb643ba8ac7ab@o4511026200117248.ingest.us.sentry.io/4511026210471936"
export RELAY_SECRET="<flauros の settings.yml に設定した shared_secret>"
EOF
chmod 600 ~/.config/capsicum/secrets.env
```

`~/.config/capsicum/` は AppStore Connect API Key (`AuthKey_WLS8G4W44L.p8`) と Google Play サービスアカウント JSON も置いているディレクトリ。リポジトリ外なので git に上がる心配はない。`chmod 600` で他ユーザーから読めないようにする。

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

> **Fastlane の実行ディレクトリ:**
> `fastlane beta` / `fastlane internal` / `fastlane release` は **必ず** `packages/capsicum/ios/`、`packages/capsicum/android/`、`packages/capsicum/macos/` のいずれか、Fastfile があるディレクトリから実行する。リポジトリルートや別ディレクトリから実行すると ipa / aab / pkg の相対パスが解決できず「Could not find ipa/aab/pkg file」エラーになり、アップロードが失敗する。v1.11.0 リリース時にこの問題で全アップロードがやり直しになった経緯がある。

### 3.4 macOS（`macos/fastlane/Fastfile`）

ビルドは事前に行い、Fastlane は TestFlight / Mac App Store への `.pkg` アップロードのみを担当する。`.pkg` の生成手順は 4.2 を参照。

```ruby
default_platform(:mac)

platform :mac do
  desc "Deploy to TestFlight"
  lane :beta do
    upload_to_testflight(
      pkg: '../build/macos/capsicum.pkg',
    )
  end

  desc "Submit to Mac App Store"
  lane :release do
    upload_to_app_store(
      pkg: '../build/macos/capsicum.pkg',
      platform: 'osx',
      submit_for_review: true,
    )
  end
end
```

> **`platform: 'osx'` が必須:**
> `upload_to_app_store` は既定で iOS の App レコードを対象にする。Universal Purchase で同一 App レコード上に macOS バージョンが乗っているため、`platform: 'osx'` を明示しないと iOS 側の最新ビルドに対する審査提出として解釈され、誤った提出になる。

## 4. リリース手順（毎回）

### 4.0 リリース前レビュー

各マイルストーンの Issue が消化済みになった後、ビルドに入る前に実施する。**単一のセキュリティレビューだけでは実用上の問題が取りこぼされる**ため、以下 5 観点を独立したサブエージェントで並列に走らせ、指摘を合流させる。

| 観点 | 焦点 |
| --- | --- |
| セキュリティ | `/security-review` スキル。認証・暗号・シークレット管理・入力検証 |
| API 契約 | Mastodon / Misskey / モロヘイヤの REST 正確性、アダプター interface の整合 |
| 並行性・ライフサイクル | async 連鎖、Riverpod provider 寿命、dispose / cancellation、race |
| エラー処理・観測性 | try/catch カバレッジ、Sentry 計装、例外の scrub、UX の可視化 |
| コーディングスタイル・規約整合性 | 用語統一（廃止語）、ハードコーディング、命名の揺れ、重複ロジック、規約違反（UI 層の Platform 分岐など） |

対象範囲は `v前リリース..HEAD` の差分。Codex（`chatgpt-codex-connector[bot]`）は PR ready 時に走るので併走させ、重複しない指摘だけを拾う。

指摘は以下の基準で分類し、必要最小限のみリリース前に対応、残りは Issue 起票して次リリース以降に送る:

- **赤（必修）**: データ破損・セキュリティ・ユーザー可視の機能不全
- **黄（余力があれば）**: 単一の edge case、観測性ギャップ
- **緑（送り）**: 将来の拡張時に顕在化しうる構造改善

v1.18 のレビューでは、この 5 観点でセキュリティ単独では見つからなかった実害バグを複数検出した（例: [#325](https://github.com/pooza/capsicum/issues/325) の enrichNotifications で unread フラグが失われるデータ破損）。残課題は [#337](https://github.com/pooza/capsicum/issues/337)-[#343](https://github.com/pooza/capsicum/issues/343) に集約。

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

> ⚠️ **環境変数は必ず `export` で親シェルに設定すること**。
> `VAR="..." flutter build ... --dart-define=KEY=$VAR` のように単一
> コマンドラインで前置すると、`$VAR` の展開はコマンドライン構築時に
> **親シェルから** 行われるため、前置した `VAR` は flutter にしか
> 環境変数として渡らず、`$VAR` は **空文字列** に展開されてしまう。
> その結果 `--dart-define=KEY=` として空値がビルドに焼き込まれ、
> Sentry / RELAY シークレットが効かない。`v1.21.0+50` ではこのミスで
> 全アカウント push 不達 (relay register 401) が発生し、`+51` で
> 再ビルド対応した。`export` 文と `flutter build` 文は **必ず別文**
> （独立した行）で書き、`\` で繋いで 1 行に圧縮しないこと。

```bash
cd packages/capsicum

# クリーンビルド（シミュレータバイナリ混入防止のため必須）
flutter clean
flutter pub get
cd ios
pod install --repo-update
cd ..

# シークレット環境変数を読み込む（1.7 で作成した secrets.env を source）
source ~/.config/capsicum/secrets.env

# 値が空でないか確認（空展開事故の予防、+50 で踏んだ罠を再発させない）
echo "SENTRY_DSN length=${#SENTRY_DSN} RELAY_SECRET length=${#RELAY_SECRET}"
# 両方とも 0 でないこと。0 だと secrets.env が壊れているか source 失敗

# iOS: ビルド → TestFlight アップロード
flutter build ipa --release \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=SENTRY_ENV=production \
  --dart-define=RELAY_SECRET=$RELAY_SECRET
cd ios
fastlane beta
cd ..

# Android: ビルド → Play Store 内部テストトラックにアップロード
flutter build appbundle --release \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=SENTRY_ENV=production \
  --dart-define=RELAY_SECRET=$RELAY_SECRET
cd android
fastlane internal
cd ..

# macOS: flutter build → xcodebuild archive → exportArchive で .pkg 生成 → TestFlight アップロード
# `flutter build macos` 単体では Apple Development 署名 + Mac App Development profile が
# 埋め込まれるだけで App Store 提出には使えない。Generated.xcconfig に DART_DEFINES を反映
# させたうえで xcodebuild archive 経由で Apple Distribution + Mac App Store profile に切り替える。
flutter build macos --release \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=SENTRY_ENV=production \
  --dart-define=RELAY_SECRET=$RELAY_SECRET
xcodebuild -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -archivePath build/macos/capsicum.xcarchive \
  -allowProvisioningUpdates \
  archive
xcodebuild -exportArchive \
  -archivePath build/macos/capsicum.xcarchive \
  -exportOptionsPlist macos/ExportOptions.plist \
  -exportPath build/macos \
  -allowProvisioningUpdates
# build/macos/capsicum.pkg が生成される
cd macos
fastlane beta
cd ..
```

> **macOS の `.pkg` 生成が iOS と異なる理由:**
> iOS は `flutter build ipa --release` 一発で App Store 提出可能な ipa が出来るが、macOS の `flutter build macos --release` は Apple Development 証明書 + Mac App Development profile を埋め込んだ `.app` を出力するだけで、Mac App Store には提出できない。`xcodebuild archive` + `-exportArchive` を経由することで Apple Distribution + Mac App Store profile + 3rd Party Mac Developer Installer による `.pkg` 署名が automatic に行われる。`flutter build macos` を先に走らせるのは Generated.xcconfig の `DART_DEFINES` を更新するため（archive 単独では `--dart-define` を渡せない）。

### 4.3 製品版昇格・審査提出

```bash
cd packages/capsicum

# Android: 内部テスト → 製品版に昇格
cd android && fastlane release && cd ..

# iOS: App Store 審査提出
cd ios && fastlane release && cd ..

# macOS: Mac App Store 審査提出
cd macos && fastlane release && cd ..
```

審査提出時のリリースノート（「このバージョンの新機能」欄）には、そのバージョンの変更内容の要約を記載すること。

### 4.4 GitHub Release のリリースノート

GitHub Release のリリースノートで「既知の不具合」セクションを作る場合は、ハードコードせず **bug ラベルが付いた open Issue を列挙** する。固定の文言は実態とズレるため、Issue が正本となるように書く。

```bash
gh issue list --label bug --state open
```

この結果をもとにリリースノートの「既知の不具合」を構築する。

## 5. 配布方針

- **iOS**: TestFlight 外部テスター経由（内部テスターは本名相互公開の問題があるため不使用）
- **Android**: Google Play で直接配布（GitHub Releases への APK 添付は v1.5.1 で廃止）
- **macOS**: Mac App Store 一本（.dmg / Developer ID 配布は採用しない）。「App Store からのアプリのみ許可」設定のユーザーに届かない問題と、署名・公証・更新通知の二重メンテを避けるため。詳細は [release-pipeline.md](release-pipeline.md) 参照
- **Google Play アカウント**: 法人（Google Workspace）アカウントのため、クローズドテスト 12 人要件は免除
- **ホットフィックス**: Fastfile の構成上 internal → promote の手順が必要（production に直接アップロードは不可）
- **App Store の説明文更新**: リリース提出時のみ可能。随時更新はできない
- **Google Play の説明文更新**: 随時更新可能だが審査あり
