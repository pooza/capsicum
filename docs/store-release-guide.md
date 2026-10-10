# ストアリリースのセットアップと配布方針

⚠⚠ **毎回回す手順（§4）は Claude Code のスキルへ移した（#1114・2026-09-13）→ [.claude/skills/store-release/](../.claude/skills/store-release/SKILL.md)（`/store-release`）。このファイルに残っているのは「一度だけの作業」と「配布方針」。**

⚠ **工程ごとに補助ファイルへ割ってある**（ビルド / 提出 / GitHub Release / Linux / Windows / 後片づけ）。1 ファイルのままだと、呼んだ時点で 60 KB が載るため。⚠ **節番号（§4.2 等）は振り直していない** —— 対応表はスキルの冒頭にある。

| | 置き場 |
| --- | --- |
| 署名鍵・API Key・fastlane の初期設定・ストア掲載情報・配布方針 | **このファイル**（§1〜§3・§5） |
| 毎回のリリース手順 | [store-release スキル](../.claude/skills/store-release/SKILL.md)（§4） |
| リリース前レビュー | [release-review スキル](../.claude/skills/release-review/SKILL.md)（§4.0） |

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
export RELAY_SECRET="<リレーサーバーの settings.yml に設定した shared_secret>"
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

ビルドは事前に行い、Fastlane は TestFlight / Mac App Store への `.pkg` アップロードのみを担当する。`.pkg` の生成手順は [store-release スキルの build-upload.md](../.claude/skills/store-release/build-upload.md)（§4.2）。

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

## 5. 配布方針

- ⚠⚠ **ベータ版のテスターは、プリセットサーバーの利用者に限る**（TestFlight の外部テスターも Google Play のクローズドテストも同じ範囲）。ベータ版の購入はサンドボックス扱いで本番のリレーでも有効になるが、プリセットの利用者はもともと無償なので、無料で使える人は増えない（[paid-relay-plan.md](paid-relay-plan.md) 7-2）
- **iOS**: TestFlight 外部テスター経由（内部テスターは本名相互公開の問題があるため不使用）
  - ⚠ **外部テスター向けにはベータ版の審査が入る。**アップロードの処理が終わっても、審査を通るまで外部テスターには配られない。状態は `.claude/scripts/asc-status.rb builds`（内部 / 外部 / 審査を分けて出す）
  - ⚠⚠ **審査は 2 本を並行できない。**前のビルドが審査待ちの間に新しいビルドを出すには、**前のビルドの審査を止めてから、新しいビルドを出し直す**（App Store Connect での手作業・2026-10-06 に 194 → 195 で踏んだ）。⚠ **自動では移らない**ので、短い間隔でビルドを重ねると、そのたびに待ち行列へ並び直すことになる
  - **審査が動かないときの催促（優先審査の依頼）は Apple Developer のサイトにある。**App Store Connect の中ではない → <https://developer.apple.com/contact/app-store/?topic=expedite>（アプリとプラットフォームを選んで送るだけ）。⚠ **フォームに理由を書く欄は無い**（公式ヘルプ [Request an expedited review](https://developer.apple.com/help/app-review/after-submitting-for-review/request-expedited-review) は、理由を提出時の「メモ」欄に書くよう案内している）。⚠ 公式ヘルプが説明しているのは App Store の審査だけで、**ベータ審査に効くかは書かれていない**。⚠ **2026-10-07 に 196 で出して受理はされたが、審査は始まらなかった**（＝ 少なくともこの回は効いていない）
  - ⚠ **催促するかどうかは、待ち時間を測ってから決める。**上のコマンドが各ビルドのアップロード時刻と審査待ちの時間を出す。⚠ **取り下げたビルドの提出時刻は API から消える**ので、出し直しをまたいだ積算はアップロードの時刻で数える
- **Android**: Google Play で直接配布（GitHub Releases への APK 添付は v1.5.1 で廃止）
- **macOS**: Mac App Store 一本（.dmg / Developer ID 配布は採用しない）。「App Store からのアプリのみ許可」設定のユーザーに届かない問題と、署名・公証・更新通知の二重メンテを避けるため。詳細は [release-pipeline.md](archive/release-pipeline.md) 参照
- **Linux**: AppImage 単独（Flathub は [#604](https://github.com/pooza/capsicum/issues/604) で 2026-05-29 に断念、Snap は不採用）。GitHub Releases に添付して即座に配布。手順は [store-release スキルの linux.md](../.claude/skills/store-release/linux.md)（§4.5）
- **Google Play アカウント**: 法人（Google Workspace）アカウントのため、クローズドテスト 12 人要件は免除
- **ホットフィックス**: Fastfile の構成上 internal → promote の手順が必要（production に直接アップロードは不可）
- **App Store の説明文更新**: リリース提出時のみ可能。随時更新はできない
- **Google Play の説明文更新**: 随時更新可能だが審査あり

### Google Play のテストトラック

⚠⚠ **API 名が直感と逆。**取り違えると**未出荷の版が誰でも入れられる**状態になる。

| API 名 | Console の呼称 | 審査 |
| --- | --- | --- |
| `internal` | 内部テスト | ⚠ **無い** |
| **`alpha`** | **クローズドテスト** | ⚠⚠ **ある** |
| `beta` | オープンテスト | ある |
| `production` | 製品版 | ある |

⚠⚠ **招いた外の人は `alpha`（クローズドテスト）へ入れる。内部テストには入れない。**`release` レーンが**内部トラックの現在のリリースを製品版へ昇格する**作りなので、内部に人を入れると**出荷直前の全ビルド**（差し替えて捨てたものを含む）が流れる（#1230）。⚠ iOS 側も理由は違うが同じ線（上の「配布方針」の 1 行目）。

#### 名前とスコープ

⚠⚠ **アプリが capsicum だけではない**（Tsunagal が 2026-10 に加わった）。**どこにアプリ名を入れるかはスコープで決まる。**

| もの | スコープ | アプリ名 |
| --- | --- | --- |
| トラック（表示名） | **アプリごと** | ⚠ 不要 |
| リリース名（`2.0.0 (193)` 等） | **アプリごと** | ⚠ 不要 |
| **テスターのメールリスト** | ⚠⚠ **アカウント共通** | ⚠⚠ **必要**（他アプリのリストと並ぶ） |

⚠ **トラックの表示名は変えてよい。**Play Developer API の `Track` は **`track`（ID）と `releases` しか持たない**ので（2026-10-05 実測）、`fastlane` の `track: 'alpha'` は表示名に影響されない。

🔴 **ただし「新しいクローズドトラックを作る」のは別物。**新しい ID になるため、`fastlane alpha` は**古い空のトラック**を指したまま「上げたつもりで誰にも届かない」になる。**名前を変えるのであって、作り直さない。**

⚠⚠ **開発者自身も、参加していないトラックの配信は受け取らない**（2026-10-05 に踏んだ）。内部テストに参加している端末は、クローズドテストにだけ載せた版が**降りてこない**。⚠⚠ **複数のトラックに参加しているときに「どれが配られるか」は確かめていない。**2026-10-05 に内部 192 / クローズド 193 の状態で**内部の 192 が配られた**が、原因が優先順位だったのか端末のキャッシュだったのかは切り分けられていない（下のキャッシュの件で解決したため）。⚠ **推測で説明しないこと。**

⚠⚠ **開発者のアカウントは、クローズドテストに参加しない**（2026-10-10 pooza 決定）。クローズドテストに参加したあと、内部テストの版が端末に出なくなった。そのときの状態:

- トラックは内部 199 / クローズド 196 / 製品版 198、端末に入っているのは 198（Play ストア経由）
- Play ストアのアプリは「capsicum（ベータ版）」「ベータ版テスター」と表示し、更新ボタンを出さない（クローズドの 196 は 198 より古い）
- Play Console の内部テストの名簿と参加状態は正常に見える。クローズドの名簿から外しても、端末の表示は変わらなかった
- 個人側の Google アカウントは 1 つ（仕事用プロファイルのアカウントは別ユーザーで、Play ストアの切り替えには出ない）。権限や対応端末の設定は 198 から変えていない

**原因は特定できていない。**「両方に参加していれば番号の大きい版が配られる」という一般的な説明は、上の 2026-10-05 の回と合わせて 2 回当てはまらなかったので、当てにしない。クローズドへ配る版は内部テストから昇格したものなので、**開発者は内部テストで同じ版を先に受け取って確かめる。**Microsoft Store でベータ配布の機能を原則使わないのと同じ考え方（[windows.md](../.claude/skills/store-release/windows.md)）。⚠ **切り分けに「反映の遅れ」を持ち出さない**（原因が分かったあとに 1 時間以上待たされた実績は無い）。端末の表示は `adb` で読める（`market://details?id=…` を開いて `uiautomator dump`）。

⚠⚠ **クローズドテストへは、内部テストに載せた版を昇格して上げる**（2026-10-06 pooza 判断・「内部テストのほうが版が低い」を起こさないため）。AAB を `alpha` へ直接上げると内部テストが取り残されるので、`alpha` レーンは昇格だけをする作りに変えた:

```sh
fastlane internal                  # AAB を内部テストへ
fastlane alpha version_code:<code> # その版をクローズドテストへ昇格（⚠ 審査が入る）
```

⚠ **この順で上げた直後、Console はしばらく「内部テスト 193 / クローズドテスト 194」と出る**（2026-10-06・194 の回）。API は直後から両方 194 を返しており、**何も操作しないまま 10〜20 分ほどで Console も 194 になった** ＝ 反映の遅れ。⚠⚠ **アップロード直後に Console が古い版を出していても、すぐ手を打たない**（193 の回は短時間に複数の操作を重ねて、何が効いたか分からなくなった）。⚠ 遅れているのが Console の表示なのか配信なのかは区別できていない。

⚠ **昇格の向きは内部 → クローズドの一方向にする。**下の `supply` の直打ちは、2026-10-05 にクローズドへ先に上げてしまった 193 を内部へ戻すために使った逆向きの手当てで、通常は要らない。

⚠ **確実なのは「同じ版を両方のトラックに載せれば、どちらが選ばれても同じものが降りる」**。やり方は promote で、⚠⚠ **`deactivate_on_promote` を `false` にする**（既定は `true` で、**元のトラックが無効化されてテスターが締め出される**）:

```sh
fastlane supply --package_name net.shrieker.capsicum \
  --track alpha --track_promote_to internal --version_code <code> \
  --deactivate_on_promote false \
  --skip_upload_metadata true --skip_upload_images true \
  --skip_upload_screenshots true --skip_upload_changelogs true \
  --json_key ~/.config/capsicum/google-play-service-account.json
```

⚠ **`--version_code` だけ渡して全部 skip すると「やることが無い」と言って止まる**（`No local metadata, apks, aab, or track to promote were found`）。トラックへの割り当ては promote でしか入らない。

🔴 **審査済みバイナリのトラック割り当ては審査が不要なので、公開管理の保留に入らず即座に通る。**「公開の概要」に何も出ないのは正常。

#### 新しい版が端末に降りてこないときに試したこと（⚠⚠ 何が効いたかは特定できていない）

**2026-10-05 に約 1 時間詰まった。**クローズドテストに 193 を載せ、公開も済んでいるのに、端末（内部テストに参加中・192）に **192 しか降りてこなかった**。

⚠⚠ **以下を順にやって最後に 193 になったが、どれが効いたのかは分からない。**短時間に複数の操作をしたうえ、**経過時間そのものが効いた可能性も消せない**（配信の反映には時間がかかる）。⚠ **次に詰まったときは 1 つずつ試して切り分けること。**

1. クローズドテストのオプトイン（`https://play.google.com/apps/testing/<パッケージ名>`）
2. 193 を内部トラックにも割り当て（上の promote）
3. Play ストアアプリの**キャッシュ削除**
4. **Play ストアアプリの再起動 + 画面のリロード** ← この直後に 193 になった

⚠ **1 と 2 はどちらか片方で足りた可能性がある**（端末がどちらのトラック経由で受け取ったのか判別できない）。⚠ **3 と 4 も、単に時間が経っただけかもしれない。**

ただし**順序から言えることが 1 つある**。⚠⚠ **1 と 2 を済ませた時点ではまだ 192 だった** ＝ **どちらも単独では不十分**で、**最後の一手（3 / 4 / 経過時間のいずれか）は必要だった**。

⚠ **「クローズドテストにだけ上げて切り分ける」という案は取り下げた**（2026-10-06）。内部テストのほうが版が低い状態をわざと作ることになり、上の「内部 → クローズドへ昇格する」と両立しない。⚠ **どちらのトラック経由で届くのかは未確定のまま**だが、両方に同じ版が載っていれば実害は無い。

🔴 **確実に言えるのはこれだけ**: ⚠⚠ **「アップロードした」「トラックに載っている」「公開を押した」は、いずれも端末に降りることを意味しない。**⚠ **端末側の状態は API からは一切見えない**ので、最終確認は実機でしか取れない。

#### 管理対象の公開（managed publishing）が入ると、API の見え方が当てにならない

🔴 **capsicum は「管理対象の公開: オン」で運用している**（2026-10-05 に初めて影響を受けた）。⚠⚠ **審査を通った変更が、Console で明示的に公開するまで止まる。**

⚠⚠ **止まっている間も、Play Developer API は「配信済み」のように返す。**

```text
API: track=alpha  status=completed  versionCodes=193   ← まだ誰にも届いていない状態でもこう返る
```

**押す前と押した後で API の出力は 1 文字も変わらなかった**（2026-10-05 実測）。⚠⚠ **つまり `fastlane` の「アップロード成功」や API のトラック確認は、「テスターが入れられる」ことの証明にならない。**最終確認は**実際に端末へ降りてくるか**でしか取れない。

⚠ **テスターの増減も止まる。**バイナリに触らない変更（メールリストの割り当て等）でも、公開管理の保留に入るので**押すまで効かない**。⚠ 「審査が要るもの」と「要らないもの」は**保留一覧の上で区別がつかない**。

⚠ 公開の画面（`/publishing`）では、**保留中の変更が「変更されたアイテム / 説明」の表**で出る。⚠ **「完全公開を開始」等は説明文であってボタンではない** —— 押すボタンは右上の「N 件の変更を公開」。⚠⚠ **押すと一覧の全件がまとめて出る**ので、**製品版やストアの掲載情報が混ざっていないか**を先に見る。
⚠ **テスターのメールリストは API から触れない**（`Testers` リソースは `googleGroups` しか受け付けない）。⚠ **メールアドレスでの指定は Play Console の手作業**。

⚠ **審査ステータスを API から追う口は無い**（トラックの `status` は配信済みを指すだけ）。Console で見る。
