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
> App Store Connect API Key（`.p8`）を `~/.config/capsicum/AuthKey_<KEY_ID>.p8` に配置すること。
> Fastlane の Fastfile はこのパスを参照する。`<KEY_ID>` / `<ISSUER_ID>` の実値は public リポジトリには書かず、各マシンの `~/.config/capsicum/` 配下と開発者の手元で管理する。
> 配布用証明書（Apple Distribution）は Xcode → Settings → Accounts → Manage Certificates で追加する。

### 1.4 macOS 署名 / Universal Purchase（v1.21 で初回セットアップ）

macOS ネイティブビルドは iOS と同じ Bundle ID `jp.co.b-shock.capsicum` を Universal Purchase で紐付け、AppStore Connect 上は同一 App レコードで管理する方針。配布は **Mac App Store 一本**（.dmg / Developer ID 配布は採用しない — [release-pipeline.md](archive/release-pipeline.md) 参照）。

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
> iOS で使用している APNs Auth Key（`AuthKey_<KEY_ID>.p8`）は macOS でもそのまま使える。`capsicum-relay` 側の APNs 接続も Bundle ID `jp.co.b-shock.capsicum` 単一で iOS / macOS 両プラットフォームを処理する。
>
> **Sandbox と flutter_secure_storage:**
> Debug entitlements では `app-sandbox=false` で運用している（ad-hoc 署名 + sandbox 有効では `errSecMissingEntitlement (-34018)` で flutter_secure_storage が動かないため）。development 署名（Apple Developer Team 紐付け済み）が通れば Debug でも sandbox を有効化できる見込み。Release entitlements は常に sandbox 有効。

### 1.5 プライバシーポリシー

- [x] プライバシーポリシーの作成
- [x] [capsicum.shrieker.net/privacy-policy](https://capsicum.shrieker.net/privacy-policy) で公開（正本は [capsicum-site](https://github.com/pooza/capsicum-site) の `privacy-policy/index.md`）
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

`~/.config/capsicum/` は AppStore Connect API Key (`AuthKey_<KEY_ID>.p8`) と Google Play サービスアカウント JSON も置いているディレクトリ。リポジトリ外なので git に上がる心配はない。`chmod 600` で他ユーザーから読めないようにする。

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

#### 差分レビュー（プラットフォーム追加・大更新マイルストーンのみ 2 回目）

新サーフェス導入時（macOS native v1.21・push relay v1.18・Misskey messages v1.22・Linux v1.24 等）は、1 回目で見つけた問題への修正 commit 自体が新しい問題を入れることがあり、平場のマイルストーンより 2 回目を回す価値が高い。以下のルールで実施する:

- **対象**: 1 回目以降の差分（`git diff <1回目時点のSHA>..HEAD`）と、新規追加されたサーフェスのみ。全文再走査はしない
- **タイミング**: リリース 1 週間前までに完了させる。直前に出た P1 は焦って広げず **ホットフィックス前提で次リリースに送ってよい**
- **何回目のマイルストーンでも対象になる**: 「大更新独立配置」のマイルストーンは定義上対象。それ以外は実施しない（issue 累積を避けるため）

v1.18 のレビューでは、この 5 観点でセキュリティ単独では見つからなかった実害バグを複数検出した（例: [#325](https://github.com/pooza/capsicum/issues/325) の enrichNotifications で unread フラグが失われるデータ破損）。残課題は [#337](https://github.com/pooza/capsicum/issues/337)-[#343](https://github.com/pooza/capsicum/issues/343) に集約。

#### リリース PR 前のローカル整形・解析チェック

`analyze.yml`（CI の `dart format` / `dart analyze`）は `main` への push / PR でのみ起動し、**`develop` への push では走らない**。そのため `develop` 上では format / analyze の drift が CI 未検出のまま蓄積しうる。リリース PR（`develop` → `main`）を作る前に、リポジトリルートで一度全体をチェックしてリリース PR の CI 不合格を未然に防ぐこと:

```bash
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
```

v1.27 では `timeline_provider.dart` / `preferences_provider.dart` が `dart format` 未追従のまま `develop` に積まれており、リリース直前のレビューで検出して整形した（commit `e377c5f`）。

### 4.1 バージョン更新・依存関係の更新

```bash
# pubspec.yaml の version を更新（例: 1.0.0+1 → 1.0.1+2）
# 注意: ビルド番号（+N）は一度ストアにアップロードすると、リリースを破棄しても再利用不可。
# 上げ直す場合は必ずビルド番号をインクリメントすること。

# Windows の MSIX パッケージバージョンは手動更新不要（#798）。windows-release.yml が
# pubspec の version(+build) から <major>.<minor>.<build>.0 を導出し --version で
# msix:build / msix:pack に渡す（pubspec の msix_config.msix_version は未指定）。
# 第4オクテット（Revision）は Store 予約で 0 固定、ビルド番号を第3オクテットに載せて
# full name を一意化する。この自動化以前は msix_version を手動で上げる運用で、上げ忘れると
# 1.43.0.0 のまま固定され、開発中の Store フライトが同じ full name を消費していると
# 製品版提出が「フル ネーム 9AFBB08E.capsicum_X.Y.Z.0_X64 が重複」で弾かれた（v1.43.0 で実踏）。

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

> ⚠️ **各プラットフォームは「ビルド → beta アップロード（§4.2）→ 審査提出（§4.3）」まで一気通貫でやり切ってから次の OS に移ること。** `flutter clean` は `build/` 全体を消すため、iOS をビルド→beta 後に Android / macOS をビルドすると、その `flutter clean` で `build/ios/ipa/capsicum.ipa` が消え、§4.3 の iOS `fastlane release`（`ipa:` パスを検証する）が `Could not find ipa file` で落ちる（v1.43.0 で実際に踏んだ）。加えて **iOS/macOS のアーカイブはビルド毎にビルド番号を自動 +1 する**ため、消えた ipa を後から再ビルドすると番号がズレ（147→148）、`skip_binary_upload:true` の deliver が「未アップロードの 148」を待ち続けてハングする。復旧するなら、`ipa:` を外して `app_identifier:` + `build_number:'<既に VALID なビルド番号>'` を渡した `upload_to_app_store`（`skip_binary_upload:true`）で既存ビルドを名指し提出する。

#### Android: 16KB ページサイズ対応（必須・irondash をローカルビルド）

Google Play は **64bit ネイティブ `.so` の LOAD セグメントが 16KB 整列**（`p_align >= 16384`）でないと製品版昇格を `Artifact does not support 16KB page size` で拒否する（2026-06 にハード強制が有効化。それ以前は警告だったため v1.41.1 までは 4KB のまま production に出ていた）。

問題のライブラリは `irondash_engine_context`（`super_drag_and_drop` → `super_native_extensions` の transitive 依存）。cargokit はデフォルトで **GitHub の precompiled `.so` をダウンロード**して使うが、irondash 0.5.5（最新）の precompiled は 4KB 整列で upstream に修正版がない（姉妹の super_native_extensions は precompiled が 16KB 済み）。precompiled は再整列できないため、**ローカル Rust ビルドに切り替えて 16KB リンカフラグを注入**する。

恒久設定（コミット済み）: [`packages/capsicum/android/cargokit_options.yaml`](../packages/capsicum/android/cargokit_options.yaml) に `use_precompiled_binaries: false`。これで cargokit は irondash / super_native_extensions をローカルビルドする。

**Android ビルドマシンの前提**: rustup + android ターゲットが必要（cargokit は rustup 不在だと precompiled に戻る）。

```bash
# 一度だけ（rustup 未導入のマシン）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
```

`flutter build appbundle` を走らせる際、§4.2 の手順に加えて **リンカフラグを export し、stale な gradle daemon を止める**（daemon が古い環境を握っていると cargokit にフラグが渡らず 4KB のままになる。一度これで踏んだ）:

```bash
export PATH="$HOME/.cargo/bin:$PATH"          # rustup を PATH に
export CARGO_ENCODED_RUSTFLAGS='-Clink-arg=-Wl,-z,max-page-size=16384'
( cd android && ./gradlew --stop )            # 古い daemon を破棄（新 daemon に env を継承させる）
flutter clean && flutter pub get
# …§4.2 の flutter build appbundle …
```

**アップロード前に必ず整列を検証する**（フラグが silent に効かないことがあるため必須ゲート）:

```bash
cd packages/capsicum
unzip -o build/app/outputs/bundle/release/app-release.aab 'base/lib/arm64-v8a/*.so' -d /tmp/so >/dev/null
# 各 .so の PT_LOAD p_align が 16384 以上であること（特に libirondash_engine_context_native.so）
for f in /tmp/so/base/lib/arm64-v8a/*.so; do
  printf '%s ' "$(basename "$f")"
  python3 - "$f" <<'PY'
import sys,struct
d=open(sys.argv[1],'rb').read(); off=struct.unpack_from('<Q',d,0x20)[0]
es=struct.unpack_from('<H',d,0x36)[0]; n=struct.unpack_from('<H',d,0x38)[0]; m=0
for i in range(n):
    o=off+i*es
    if struct.unpack_from('<I',d,o)[0]==1: m=max(m,struct.unpack_from('<Q',d,o+0x30)[0])
print('align',m,'OK' if m>=16384 else 'BAD')
PY
done
```

`libirondash_engine_context_native.so` が `BAD align=4096` なら、上の export / daemon 停止が効いていない。直してから upload すること。

### 4.3 製品版昇格・審査提出

#### ストア掲載文の見直し要否（提出前に必ず判断する）

App Store は**説明文・キーワード・スクリーンショットをバージョン提出時にしか更新できない**（随時更新不可、§5）。このリリース提出が唯一の更新機会なので、毎リリースの提出前に「この版でストア掲載文の更新が要るか」を意識的に判断する。**見直し不要なリリースが大半**だが、以下に該当すれば正本の [store-listing.md](store-listing.md)（§2.1）を更新し、今回の提出に含める:

- 看板機能・大更新の追加で説明文の訴求が変わる
- 対応プラットフォーム / 対応 SNS / 配布チャネルの変化
- 用語統一・呼称変更が UI からストア文にも波及する
- スクリーンショットが現行 UI と乖離している

「不要」と判断した場合もそれを意識的に確認してから進む（先送りすると次リリースまで反映できない）。Google Play は随時更新できるが、齟齬を避けるため同じタイミングで揃える。なお capsicum-site の説明文は随時更新できるので、サイト側は §4.7（リリース後）で扱う。

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

> ⚠️ **iOS の `fastlane release` は §4.2 の ipa が build/ に残っている前提**。iOS ベータの後に Android / macOS を `flutter clean` 込みでビルドすると `build/ios/ipa/capsicum.ipa` が消え、`skip_binary_upload: true` でもレーンが ipa パスの存在検証で `Could not find ipa file` で落ちる。復旧は `flutter build ipa`（build 番号据え置き = 再アップロードされない）で ipa を再生成してから `fastlane release`。ただし再生成後の submit で deliver が **「Waiting for the build to show up in the build list」ループから抜けられずハングする**ことがある（既存 build は ASC 上に存在するのに API 選択が回らない。v1.44.0 で発生）。数分待って進まなければ **ASC UI から該当 build を手動で「審査へ提出」する方が速い**（1分程度）。macOS の pkg は最後にビルドしたものが残るため、iOS の ipa 再生成で `flutter clean` する前に macOS の submit を先に済ませること。
>
> ⚠️ **fastlane の出力を `| tail` 等にパイプしない**。パイプすると `$?` がパイプ末尾コマンド（tail）の exit code になり、**fastlane の失敗を取りこぼす**。ログはファイルにリダイレクトし（`fastlane release > log 2>&1; echo $?`）、exit code を明示確認すること。
>
> ⚠️ **`fastlane release`（Android）は内部トラックの「現在の」リリースを製品版へ promote する**ため、自分の `fastlane internal` アップロードが失敗していると、トラックに残っている**別ビルドを誤って昇格**しうる。とくに**複数端末で並行ビルドすると versionCode が衝突**し（Google Play は同一トラックの versionCode 重複を拒否）、後発の upload が失敗→既存ビルドが promote される事故が起きる。v1.35.0 で実際に「マージン調整前の 102」が製品版に出た（`| tail` で upload 失敗を見落とし）。**対策**: (1) build 後に実バイナリで versionCode と secrets を確認、(2) 昇格後に Play API で production の versionCode が意図どおりか確認する（手順は §4.4 の Play 版確認、または ASC 同様の service-account JWT で `edits.tracks.get`）。衝突時は `flutter build appbundle --build-number=<次番号>` で採番し直して再 upload→再 promote。

#### サポーター（投げ銭）IAP の審査ノート（[#428](https://github.com/pooza/capsicum/issues/428)、v1.27〜）

消耗型サポータープランを含むビルドを iOS / Android に提出する際は、App Review Information の Notes（App Store）／アプリのアクセス権の説明（Google Play）に [supporter-subscription-plan.md](supporter-subscription-plan.md) C-2 の英文を貼り付ける。機能差別化なし・装飾のみ・単発である旨を明示することで、機能アンロックを伴わない IAP に対する審査員の混乱を回避する。継続課金ではないため Apple Guideline 3.1.2（継続的価値）の論点は発生しない。

**新規 IAP（特に初回）は ASC 上で単独で審査提出しない。** アプリのバージョン提出に紐付けて同時提出する（バージョン提出画面の「App 内課金」欄で対象 IAP を選択）。リリース前レビュー前に IAP だけ先行提出すると、レビュー結果を取り込む前のビルドと審査がちぐはぐになるため。初回 IAP のスクリーンショット等の必須項目は「提出準備完了」状態にしておき、実提出は製品版昇格時のアプリ版提出に合わせる。初回 IAP が承認されれば 2 回目以降は単独提出も可。

投げ銭画面の金額はストアのローカライズ価格（`ProductDetails.price`）をそのまま表示する設計で、コード側に金額をハードコードしない。表示通貨は端末の App Store / Play アカウントのストア地域で決まるため、検証アカウントが日本以外（米国 sandbox 等）だと `$` 表示になる。これは不具合ではなく、日本ストアのユーザーには円で表示される（iPhone 実機で確認済み）。

#### macOS の Apple Events (temporary-exception) 審査ノート（[#668](https://github.com/pooza/capsicum/issues/668)、v1.37〜）

macOS のナウプレ挿入は、ミュージック.app（`com.apple.Music`）の**現在再生中の曲（タイトル/アーティスト/アルバム）を AppleScript で読み取る**ため、Release.entitlements に `com.apple.security.temporary-exception.apple-events` = `["com.apple.Music"]` を持つ。これは MAS 審査で必ず見られる entitlement なので、**App Review Information の Notes に下記英文を貼る**（macOS バージョン提出時）。

**なぜ temporary-exception が必要か**（capsicum での実証経緯）: modern の `com.apple.security.automation.apple-events`（boolean）だけだと、App Sandbox 下でミュージックへの Apple Events が記述子（bundleId / PID）・スレッドを問わず **procNotFound (-600)** で弾かれ、対象アプリを解決すらできない（build 109-116 の内部ベータ実機 Sentry で確定）。特定アプリ宛てを明示する temporary-exception を併用して初めて addressable になり、TCC「オートメーション」許可プロンプトが出て読み取りが成立した（build 117 で動作確認）。

審査 Notes 英文テンプレート:

```text
On macOS, capsicum's compose screen has an optional "Insert Now Playing"
button. When the user taps it, the app reads the *currently playing track's
title / artist / album* from the Music app (com.apple.Music) via Apple Events,
so the user can mention what they are listening to in a post. It is
read-only — the app never controls playback. The Apple Event is sent only on
that explicit user action, and NSAppleEventsUsageDescription explains the
purpose; the first use shows the standard Automation consent prompt.

We declare com.apple.security.temporary-exception.apple-events limited to
com.apple.Music because the modern com.apple.security.automation.apple-events
entitlement alone returns procNotFound (-600) when resolving the Music app
inside the App Sandbox, so the feature cannot work without it.
```

> 万一 temporary-exception で差し戻された場合の代替は、macOS を Developer ID 直接配布（非サンドボックス）にすること。ただし **macOS の投げ銭 IAP（#598、StoreKit）は MAS 専用**で非サンドボックス化すると失われるため、ナウプレ機能と IAP のトレードオフになる。まず temporary-exception で挑み、不可なら配布形態を pooza 判断。

#### macOS の whatsNew (新機能欄) 未入力で submit が弾かれる罠

iOS は `fastlane release` 実行時に新バージョンの `whatsNew` が空でも前バージョンの値を継承するか何らかの経路で埋められ、submit_for_review が通る。一方 **macOS は同じ Fastfile / 同じ呼び出し方でも `whatsNew` を継承しない** ため、空のまま submit_for_review に進んで Apple API がエラーを返す:

```text
The provided entity is missing a required attribute -
You must provide a value for the attribute 'whatsNew' with this request
```

v1.25.0 リリースで初めて踏んだ。エラーが出た場合は spaceship で localization に whatsNew を patch してから fastlane release を再実行する:

```ruby
require 'spaceship'
token = Spaceship::ConnectAPI::Token.create(
  key_id: '<KEY_ID>',
  issuer_id: '<ISSUER_ID>',
  filepath: File.expand_path('~/.config/capsicum/AuthKey_<KEY_ID>.p8'),
)
Spaceship::ConnectAPI.token = token

# macOS 1.X.Y バージョンの localization ID を取得し whatsNew を patch
app = Spaceship::ConnectAPI::App.find('jp.co.b-shock.capsicum')
mac_version = app.get_app_store_versions.find { |v| v.platform == 'MAC_OS' && v.version_string == '1.X.Y' }
loc_resp = Spaceship::ConnectAPI.get_app_store_version_localizations(app_store_version_id: mac_version.id)
ja_loc = loc_resp.body['data'].find { |l| l['attributes']['locale'] == 'ja' }
Spaceship::ConnectAPI.patch_app_store_version_localization(
  app_store_version_localization_id: ja_loc['id'],
  attributes: { whatsNew: "変更内容の詳細は GitHub リリースページをご覧ください。\nhttps://github.com/pooza/capsicum/releases" },
)
```

なお submit_for_review に失敗した review submission は `READY_FOR_REVIEW` で残留し、見た目上 cancellable でない (`Resource is not in cancellable state`) ことがある。次回 fastlane release で新規 submission が作られて吸収されるので無視してよい。

### 4.4 GitHub Release のリリースノート

GitHub Release のリリースノートで「既知の不具合」セクションを作る場合は、ハードコードせず **bug ラベルが付いた open Issue を列挙** する。固定の文言は実態とズレるため、Issue が正本となるように書く。

```bash
gh issue list --label bug --state open
```

この結果をもとにリリースノートの「既知の不具合」を構築する。

#### 公開状況の外形確認（App Store lookup API）

iOS / macOS の「審査提出済み」と「公開済み」の差は、Apple の iTunes Search API (lookup) で認証なしに確認できる。`currentVersionReleaseDate` が最新版のストア反映日時。

```bash
# iOS / iPadOS（bundleId は Universal Purchase 共通）
curl -sA "Mozilla/5.0" "https://itunes.apple.com/lookup?bundleId=jp.co.b-shock.capsicum&country=jp" | python3 -m json.tool

# macOS（Mac App Store、entity=macSoftware）
curl -sA "Mozilla/5.0" "https://itunes.apple.com/lookup?bundleId=jp.co.b-shock.capsicum&country=jp&entity=macSoftware" | python3 -m json.tool
```

注目フィールド: `version`（最新公開バージョン）/ `currentVersionReleaseDate`（ストア反映時刻 UTC）/ `releaseDate`（初公開日）/ `trackViewUrl`。

注意:

- User-Agent がないと空応答になることがあるため `-A "Mozilla/5.0"` を付ける。`country=us` 等で他ストアも確認できる
- **片方ストアが長期停滞中だと lookup の `version` が実態と乖離する**。Universal Purchase の `trackId` 共有の都合で、iOS と macOS のどちらか古い方の公開バージョンが優先表示されることがある（例: iOS が新版公開済みでも macOS が審査停滞中だと両 storefront とも古い方を返し続ける）。lookup は公開済みアプリの現行版しか返さないため、**審査中（`WAITING_FOR_REVIEW` / `IN_REVIEW`）かどうかや iOS / macOS の個別ステータスは原理的に分からない**

#### 審査ステータスのプラットフォーム別確認（App Store Connect API、推奨）

iOS と macOS の審査状態を**別々に正確に**取得するには App Store Connect API を使う（lookup では Universal Purchase の同一レコードを拾うため不可）。`appStoreVersions` を `platform`（`IOS` / `MAC_OS`）でフィルタすると各版に `appStoreState`（`READY_FOR_SALE` = 公開済み / `WAITING_FOR_REVIEW` = 審査待ち / `IN_REVIEW` = 審査中 / `PENDING_DEVELOPER_RELEASE` 等）が付く。**今後 iOS / macOS の公開状況確認はこの方法を第一とする**（lookup は補助）。

認証は fastlane と同じ ASC API Key（`~/.config/capsicum/AuthKey_<KEY_ID>.p8`）を流用し、ES256 JWT を生成して叩く（Ruby の `jwt` gem 利用）。`<KEY_ID>` / `<ISSUER_ID>` の実値は public リポジトリには書かず、各マシンの `~/.config/capsicum/` 配下と private な端末固有値リファレンスで管理する（このファイル冒頭 §1.3 と同じ方針）。実行前に環境変数へ入れておく:

```bash
# 実値は private リファレンス参照。例: export ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=........-....-....-....-............
ruby -e '
require "jwt"; require "net/http"; require "json"; require "uri"
KEY_ID=ENV.fetch("ASC_KEY_ID"); ISSUER=ENV.fetch("ASC_ISSUER_ID")
key=OpenSSL::PKey::EC.new(File.read(File.expand_path("~/.config/capsicum/AuthKey_#{KEY_ID}.p8")))
now=Time.now.to_i
tok=JWT.encode({iss:ISSUER,iat:now,exp:now+600,aud:"appstoreconnect-v1"},key,"ES256",{kid:KEY_ID,typ:"JWT"})
get=->(p){u=URI("https://api.appstoreconnect.apple.com/v1/#{p}");r=Net::HTTP::Get.new(u);r["Authorization"]="Bearer #{tok}";JSON.parse(Net::HTTP.start(u.host,u.port,use_ssl:true){|h|h.request(r)}.body)}
app=get.call("apps?filter[bundleId]=jp.co.b-shock.capsicum")["data"].first["id"]
%w[IOS MAC_OS].each{|pl|puts "== #{pl} ==";get.call("apps/#{app}/appStoreVersions?filter[platform]=#{pl}&limit=3")["data"].each{|v|a=v["attributes"];puts "  #{a["versionString"]}  #{a["appStoreState"]}"}}
'
```

### 4.5 Linux 配布（v1.24〜）

Linux は fastlane を使わず GitHub Actions の Ubuntu runner ジョブ ([.github/workflows/linux-release.yml](../.github/workflows/linux-release.yml)) でビルドする。配布形態は AppImage 単独（Flathub は [#604](https://github.com/pooza/capsicum/issues/604) で 2026-05-29 に断念、経緯は CLAUDE.md デスクトップ対応節を参照）。

#### AppImage

タグ駆動 (`v*.*.*`) で `linux-release.yml` の `appimage` ジョブが起動し:

1. ubuntu-22.04 で `flutter build linux --release` (glibc 2.35 互換性確保)
2. `linuxdeploy` + `linuxdeploy-plugin-gtk` で AppDir を組み立て、`appimagetool` で AppImage 化
3. `capsicum-<version>-x86_64.AppImage` を **draft Release** に添付
4. pooza が GitHub UI で draft Release をレビューしてから手動で publish

draft で生成するのは「リリース作業の委託範囲」(自動公開はしない) ルールに従う。

#### ローカル動作確認

```sh
bash packaging/linux/appimage/build.sh
```

ビルド + 起動の詳細・配布物（GitHub Releases から DL した AppImage）の検証手順は [packaging/linux/appimage/README.md](../packaging/linux/appimage/README.md) §動作確認を参照。

#### GitHub Release のリリースノート（Linux セクションテンプレート）

Linux は**ストア展開が無く、この AppImage インストールコマンドが最優先の導線**になるため、リリースノートには**必ず**この Linux セクションを入れる（v1.38 でこのセクションごと抜けた経緯あり）。手順本体は [packaging/linux/INSTALL.md](../packaging/linux/INSTALL.md) を single source of truth とし、ワンライナーは**サイト配信の install.sh**（バージョン非依存・常に最新 Release を取得）を案内する。

````markdown
## Linux (AppImage)

下記ワンライナーで最新版のダウンロード〜メニュー登録まで完了します（`sudo` 不要・`$HOME` 配下のみ）:

```sh
curl -fsSL https://capsicum.shrieker.net/install.sh | bash
```

`curl` が無ければ `wget -qO- https://capsicum.shrieker.net/install.sh | bash`。手動配置・FUSE2 fallback・アンインストールは [インストール手順](https://capsicum.shrieker.net/desktop/) を参照してください。
````

> **install.sh / uninstall.sh の site 同期チェック（毎リリース）**: `packaging/linux/install.sh` または `uninstall.sh` を変更したリリースでは、capsicum-site (`~/repos/capsicum-site`) の同名ファイルへ機能を反映して push する（`capsicum.shrieker.net/install.sh` は正本のミラー。URL を `raw.githubusercontent`→`capsicum.shrieker.net` に差し替えた本番変種なので byte 一致ではなく #707 等の機能変更を移植する形）。ワンライナーはバージョン非依存なので、スクリプト未変更のリリースでは同期不要。同期済みかは `curl -fsSL https://capsicum.shrieker.net/install.sh | grep -c '<変更の目印>'` で確認できる。

### 4.6 Windows 配布（v1.25〜）

Windows は fastlane を使わず GitHub Actions の windows-latest runner ジョブ ([.github/workflows/windows-release.yml](../.github/workflows/windows-release.yml)) でビルドする。**公式配布は Microsoft Store 単独**（[#760](https://github.com/pooza/capsicum/issues/760)、2026-07-02〜）:

- **Microsoft Store 経由** ([#544](https://github.com/pooza/capsicum/issues/544)、2026-05-20 初回審査通過): Partner Center Web UI からの **手動 publish** ルートで Store 公開。**Windows 唯一の公式配布ルート**（[apps.microsoft.com/detail/9np2gr7m2w6p](https://apps.microsoft.com/detail/9np2gr7m2w6p)）
- **自己署名 MSIX（draft Release 添付）は非公式・非サポート・案内しない**（[#423](https://github.com/pooza/capsicum/issues/423) の直配は #760 で表向き廃止、2026-07-05 に案内自体を全面停止）: CI は従来どおり `.msix` + `.cer` を draft Release に添付し**続ける**が、これは **pooza が Store 手動 publish 用に `.msix` を取り出す口**であって、エンドユーザー向けの配布経路ではない。**リリースノート・README・公式サイト・[INSTALL.md](../packaging/windows/INSTALL.md) のいずれでも import 手順を案内しない**（#599 の Store IAP が Store-install 版でしか動かず、直配版だと投げ銭できない非対称を避けるため）。Windows の配布は Microsoft Store 単独に一本化する

msstore CLI 経由の自動 publish は個人開発者アカウントから Entra ID テナント関連付け UI に到達できず引き続き保留。毎リリースの Store publish は **Partner Center Web UI から手動** が前提。

`pubspec.yaml` の `msix_config.store: false` のまま生成した自己署名 MSIX を Web UI に upload する経路で初回審査通過済み（Store 側で再署名されるため self-signed のまま submit 可）。Store 提出用の `.msix` は draft Release 添付（または CI の `capsicum-msix` artifact）から取り出して使う。

OV コード署名証明書 ([#534](https://github.com/pooza/capsicum/issues/534)) は Store 経由配布が唯一の公式ルートになったため不要（Store 経由は MS が再署名、自己署名直配は #760 で非公式化）。

#### MSIX

タグ駆動 (`v*.*.*`) で `windows-release.yml` の `msix` ジョブが起動し:

1. windows-latest (x64) で `flutter build windows --release`（jni transitive のため Microsoft OpenJDK 21 を `actions/setup-java` で導入）
2. Repository Secrets `WINDOWS_SELFSIGNED_PFX_BASE64` / `WINDOWS_SELFSIGNED_PFX_PASSWORD` から PFX を復元（未投入時は ephemeral cert にフォールバック、warning 出力）
3. `dart run msix:create --certificate-path ... --certificate-password ...` で **署名済み** `capsicum.msix` を生成（msix package が内部で signtool を呼ぶ）
4. PFX から公開鍵 `.cer` を抽出
5. `capsicum.msix` + `capsicum-signing.cer` を **draft Release** に添付（pooza が GitHub UI で publish 判断）

Microsoft Store への publish は msstore CLI 自動化が保留中のため、§「Microsoft Store 手動 publish の毎回手順」に従って Partner Center Web UI から手動で行う（同じ `capsicum.msix` を upload）。

draft で生成するのは「リリース作業の委託範囲」(自動公開はしない) ルールに従う。

#### 自己署名証明書の投入手順（一度だけ、[#423](https://github.com/pooza/capsicum/issues/423)）

PFX を Mac 側で生成して Repository Secrets に投入する。Subject は `pubspec.yaml` の `msix_config.publisher` (`CN=0B8EE9C3-CB07-4EBE-B8B8-B73E973AEE42`) と完全一致させる必要がある。

1. **PFX 生成** (Mac で openssl):

   ```sh
   # 任意のパスワードを決める
   PASSWORD="$(openssl rand -base64 24)"
   echo "$PASSWORD"  # 控える (secrets.env と同等の機密扱い)

   # 秘密鍵 + 自己署名証明書を生成 (5 年有効、Code Signing EKU)
   openssl req -x509 -newkey rsa:4096 -keyout capsicum-signing.key -out capsicum-signing.crt \
     -days 1825 -nodes \
     -subj "/CN=0B8EE9C3-CB07-4EBE-B8B8-B73E973AEE42" \
     -addext "extendedKeyUsage=codeSigning"

   # PFX (PKCS#12) にまとめる
   openssl pkcs12 -export -out capsicum-signing.pfx \
     -inkey capsicum-signing.key -in capsicum-signing.crt \
     -password pass:"$PASSWORD"

   # base64 化 (macOS では直接クリップボードへ)
   base64 -i capsicum-signing.pfx | pbcopy
   ```

2. **GitHub Repository Secrets に投入** (`https://github.com/pooza/capsicum/settings/secrets/actions`):
   - `WINDOWS_SELFSIGNED_PFX_BASE64`: 上記 base64 文字列
   - `WINDOWS_SELFSIGNED_PFX_PASSWORD`: 上記 `PASSWORD`

3. **生成物の保管**: `capsicum-signing.pfx` 本体と `PASSWORD` は **secrets.env と同等の機密扱い** で保管。再生成するとエンドユーザーが信頼ストアに再 import 必要になる。

投入後の最初のタグ駆動ビルドで `msix` ジョブが署名済み MSIX を生成する。

#### 自己署名 PFX の rotation / 失効対応 runbook

PFX は 5 年有効。**期限切れ・流出疑い・鍵管理ホスト退役のいずれかが発生したらローテーションする**。流出した場合、当該 cert で署名された任意 MSIX が既存ユーザーの `TrustedPeople (LocalMachine)` に対して auto-trust されるため、迅速な対応が必要。

ローテーション手順:

1. 上記「自己署名証明書の投入手順」を再実行し、新しい PFX を生成 → Repository Secrets を上書き
2. 次の通常リリース (または hotfix) で新 cert 署名 MSIX を draft Release に出す
3. リリースノートに「証明書ローテーションのため、初回起動前に新 `.cer` を `TrustedPeople` に再 import する必要があります」を明記。旧 `.cer` 削除手順 ([packaging/windows/INSTALL.md](../packaging/windows/INSTALL.md) のアンインストール手順末尾) もリンク

流出が確定した場合の追加対応:

- 旧 cert の Subject Key Identifier / Serial Number を release notes と [capsicum-site](https://capsicum.shrieker.net) にアナウンスし、エンドユーザーに `Cert:\LocalMachine\Disallowed` への追加 (`Set-Location Cert:\LocalMachine\TrustedPeople; Get-ChildItem | Where-Object {<対象cert>} | Move-Item -Destination Cert:\LocalMachine\Disallowed`) を案内
- OV cert 取得 (#534) を前倒しできるか検討。OV 経路に切り替われば自己署名 cert は不要になり、再発防止できる

`pubspec.yaml` の `msix_config.publisher` (`CN=0B8EE9C3-…`) を変更すると、Microsoft Store の identity 紐付け (#544) で再申請が必要になるため、ローテーション時の Subject 変更は避ける。

#### Microsoft Store 手動 publish の毎回手順（毎回・[#544](https://github.com/pooza/capsicum/issues/544)）

タグ駆動ビルドで draft Release に添付された `capsicum.msix` を Partner Center Web UI から手動で submission する。初回審査は 2026-05-20 通過、以降は同じ流れで毎リリース回す。

1. **Partner Center にログイン**: <https://partner.microsoft.com/dashboard> → アプリ「capsicum」(`identity_name=9AFBB08E.capsicum` / `publisher_display_name=小石達也`)
2. **新規 Submission を開始**
3. **Packages**: draft Release に添付された `capsicum.msix` をそのまま upload（`msix_config.store: false` のままで OK、Store 側で再署名される）
4. **Submission Options > Notes for Certification**: 毎回必須。確定文面・根本原因・Windows 固有の注意は [msstore-review-notes-login.md](msstore-review-notes-login.md) を single source of truth とする（capsicum は OAuth + 外部サーバー前提のため、書かないと Policy 10.3.1 *App Is Testable - Test Account* で差し戻し）
5. **System Requirements (推奨環境)**: 「イマーシブヘッドセット」項目に **明示的にチェックを入れる**罠あり（実体としては不要だが、UI が空欄を許容せず submission に進めない仕様。2026-05-16 にはまった経緯あり、参考: <https://mstdn.b-shock.org/@pooza/116586587890264199>）
6. **Submit for certification**: Microsoft 公称の認定期間は最大 1-3 日（初回は 3-7 日）だが、**実績では問題がなければ 1 時間程度で通過することが多い**（Android と同様に速い）。数時間経っても Pending のままなら審査で引っかかっている可能性を疑う。通過後に Store listing が自動で publish される
7. **動作確認**: Store からインストールして SmartScreen 警告なしで起動できることを確認

msstore CLI 経由の自動 publish は個人開発者アカウントから Entra ID テナント関連付け UI に到達できず引き続き保留のため、毎リリース手動で行う。

#### Microsoft Store credential 投入手順（将来 msstore CLI 自動 publish が再開した時のみ）

現状は §「Microsoft Store 手動 publish の毎回手順」を毎リリース回しているため credential 投入は不要。将来 msstore CLI 自動 publish の再挑戦が成立した時点で、Repository Secrets `MS_STORE_CLIENT_ID` / `MS_STORE_CLIENT_SECRET` / `MS_STORE_TENANT_ID` を投入すると `windows-release.yml` の publish step が自動有効化される構造を残してある（現在 secrets 未投入時 skip 動作）。

#### GitHub Release のリリースノート（Windows セクションテンプレート）

タグごとの GitHub Release description に追記するテンプレート。pooza がドラフト Release を編集する際に貼り付ける。

> ⚠️ **自己署名 MSIX 直配はリリースノートに一切書かない**（2026-07-05 方針確定）。この配布方法は今後一切案内しない。CI は従来どおり `.msix` + `.cer` を draft Release に添付し続けるが（pooza が Store 手動 publish 用に `.msix` を取り出す口）、**リリースノート・README・公式サイト・INSTALL.md のいずれでも import 手順を案内しない**。Windows の公式配布は Microsoft Store 単独（#760 をさらに徹底）。

````markdown
## Windows

Microsoft Store からインストールできます: [apps.microsoft.com/detail/9np2gr7m2w6p](https://apps.microsoft.com/detail/9np2gr7m2w6p)
````

#### Windows ローカルビルド確認

```sh
cd packages/capsicum
flutter build windows --release
dart run msix:create  # 未署名で生成 (開発者モード ON の Windows でのみ動作)
# build/windows/x64/runner/Release/capsicum.msix
```

ローカル MSIX は未署名のため、Windows 側で「開発者モード ON」 (Settings → For developers → Developer Mode) の状態でのみ `Add-AppxPackage` できる。CI 経由の署名済み MSIX は信頼ストア import 後であれば開発者モード不要。

### 4.7 リリース後の後片づけ・次マイルストーン準備（毎リリース後）

公開が一巡したら、次のマイルストーンに入る前に以下を一括で行う。**capsicum-site の更新までが 1 セット**。多くは他手順（[sync-procedure.md](sync-procedure.md) / §4.4 / [CLAUDE.md](CLAUDE.md)「マイルストーン運用」）への参照で、ここはチェックリストとして機能させる。リリース後の最初の同期セッションで sync-procedure と合わせて回すことが多い。

#### A. 公開の完走確認

- 全プラットフォームの公開状況を**実測**で確認する（§4.4 の lookup / ASC API のプラットフォーム別 `appStoreState` + Play production track の versionCode + GitHub Release が Latest か）。推測しない。
- iOS が審査中（`IN_REVIEW`）でも、通例どおり短期通過する routine のため「完走扱い」にしてよい（pooza 判断）。残りが iOS 審査のみなら待たずに次へ進む。

#### B. リリース記録の更新

- [CLAUDE.md](CLAUDE.md)「リリース計画」の「最新リリース」に新バージョンを追記し、前版をリリースログへ降格する。
- メモリ `project_v1xx_progress` を出荷状況（実測）で更新する。

#### C. capsicum-site の更新（`~/repos/capsicum-site`・master 直 push 可）

- `index.md`「最新リリース」を新版に差し替え、概要（看板・主な変更）を 1 段落で書く。
- `index.md`「主な機能」に、今回追加した目玉機能を反映する。
- `index.md` /  `desktop/index.md` のロードマップから消化済みを外し、後続マイルストーンを繰り上げる（GitHub リンクは milestone 番号が固定なので付け替えに注意）。
- 新機能・デスクトップ等の**説明文を見直す**。themed / 大更新は先に掲載してよいが、集約枠（内容が流動的な version 集約枠）はリリースが近づいてから載せる。
- ※ここで更新するのは**サイトの**説明文。**ストア掲載文は提出時しか変えられないため §4.3 で済ませている**（混同しない）。

#### D. 次マイルストーンの整備

- on-hold 解除・新規 issue を適切なマイルストーンへ振り分ける（振り分け基準・据え置き/先送り履歴の尊重は CLAUDE.md「マイルストーン運用」と MEMORY に従う）。
- 直近マイルストーンの**過積載点検**（中粒 5〜12 件 + 大更新 0〜1 件が目安）。膨れていれば、一塊のテーマ束を独立配置のマイルストーンへ分離し、以降のマイルストーンを 1 つずつ繰り下げる（連番なので、退避用の一時タイトルを経由してタイトル衝突を避けつつ tail をずらす）。
- マイルストーン description の版番号 cross-ref（「後続 v1.xx」等）を再編後の並びに整合させる。
- 次マイルストーン着手時に pubspec の version を先にバンプする（後回しにすると開発中ずっと旧版表示で混乱するため）。

#### E. 環境・互換の確認

- Mastodon / Misskey の現行バージョンを fork pull で確認する（sync-procedure §8）。メジャー / マイナーが上がっていれば API トリアージ（[mastodon-46-capsicum-triage.md](mastodon-46-capsicum-triage.md) / [misskey-capsicum-api-watch.md](misskey-capsicum-api-watch.md)）の要否を判断する。

## 5. 配布方針

- **iOS**: TestFlight 外部テスター経由（内部テスターは本名相互公開の問題があるため不使用）
- **Android**: Google Play で直接配布（GitHub Releases への APK 添付は v1.5.1 で廃止）
- **macOS**: Mac App Store 一本（.dmg / Developer ID 配布は採用しない）。「App Store からのアプリのみ許可」設定のユーザーに届かない問題と、署名・公証・更新通知の二重メンテを避けるため。詳細は [release-pipeline.md](archive/release-pipeline.md) 参照
- **Linux**: AppImage 単独（Flathub は [#604](https://github.com/pooza/capsicum/issues/604) で 2026-05-29 に断念、Snap は不採用）。GitHub Releases に添付して即座に配布。手順は §4.5 参照
- **Google Play アカウント**: 法人（Google Workspace）アカウントのため、クローズドテスト 12 人要件は免除
- **ホットフィックス**: Fastfile の構成上 internal → promote の手順が必要（production に直接アップロードは不可）
- **App Store の説明文更新**: リリース提出時のみ可能。随時更新はできない
- **Google Play の説明文更新**: 随時更新可能だが審査あり
