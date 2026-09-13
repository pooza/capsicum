### 4.3 製品版昇格・審査提出

#### 内部ベータで検証したビルドをそのまま審査へ回す（iOS / macOS・v1.53〜）

iOS / macOS の `release` レーンは **`skip_binary_upload: true`** なので、**§4.2 の `beta` で TestFlight へ上げたビルドをそのまま審査提出できる**。ビルド番号をバンプして作り直す必要はない。

これは単なる手間の節約ではなく、**pooza が内部ベータで実機確認したバイナリと、審査へ出す成果物を一致させる**ための運用。バンプして作り直すと「検証していないビルドを提出する」ことになり、内部ベータを挟む意味が薄れる。pubspec の `+<build>` とも整合が取れる。

`release` レーンは `ipa:` / `pkg:` のパスを**存在検証にだけ**使う（アップロードはしない）ため、ファイルの実体は必要。したがって:

- **iOS ベータ → macOS ビルドの順に走らせると、macOS 側の `flutter clean` で `build/ios/ipa/capsicum.ipa` が消える**（下の ⚠️ と同じ罠）。**beta の直後にスクラッチ領域へ `cp` して退避し、submit の直前に戻すのが最も確実**（v1.53 ではこれで復旧作業ゼロで通した）
- macOS の `.pkg` は最後にビルドしたものが残るので、Apple 2 つを submit するときは **macOS → iOS の順**にすると退避が 1 つで済む

Android は `flutter build appbundle` → `fastlane internal` → `fastlane release` の流れが必要なので対象外（`release` が内部トラックの「現在の」リリースを promote する仕様）。**Android のビルドは Apple 2 つの submit が終わってから走らせること**（`flutter clean` が `.pkg` と `.ipa` を両方消す）。


#### ストア掲載文の見直し要否（提出前に必ず判断する）

App Store は**説明文・キーワード・スクリーンショットをバージョン提出時にしか更新できない**（随時更新不可、§5）。このリリース提出が唯一の更新機会なので、毎リリースの提出前に「この版でストア掲載文の更新が要るか」を意識的に判断する。**見直し不要なリリースが大半**だが、以下に該当すれば正本の [store-listing.md](../../../docs/store-listing.md)（§2.1）を更新し、今回の提出に含める:

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

#### 「このバージョンの新機能」欄（whatsNew）は定型文で運用する

App Store / Mac App Store の `whatsNew` は、**バージョンごとの要約を書かず、GitHub リリースページへの誘導文で固定**する:

```text
変更内容の詳細は GitHub リリースページをご覧ください。
https://github.com/pooza/capsicum/releases
```

`upload_to_app_store` は前バージョンの値を引き継ぐので、通常のリリースでは**何もしなくてよい**（macOS が引き継がず弾かれた場合の復旧は下の「whatsNew 未入力で submit が弾かれる罠」を参照）。

**リリースノートの正本は GitHub Release 1 箇所**（§4.4）。ASC 側にも要約を置くと、Linux / Windows を含む全プラットフォーム向けの本文と、Apple 2 つだけに出る本文が二重管理になり、片方が陳腐化する。誘導文なら常に最新を指す。

> この節はもともと「そのバージョンの変更内容の要約を記載すること」と書かれていたが、**v1.53〜v1.56 の iOS / macOS はすべて上記の定型文で提出されており**、記述が実態と合っていなかった（2026-08-13 の v1.56 リリース時に ASC API で実測して発覚）。pooza の判断で**実態に合わせる**方向で確定した。

> ⚠️ **iOS の `fastlane release` は §4.2 の ipa が build/ に残っている前提**。iOS ベータの後に Android / macOS を `flutter clean` 込みでビルドすると `build/ios/ipa/capsicum.ipa` が消え、`skip_binary_upload: true` でもレーンが ipa パスの存在検証で `Could not find ipa file` で落ちる。復旧は `flutter build ipa`（build 番号据え置き = 再アップロードされない）で ipa を再生成してから `fastlane release`。ただし再生成後の submit で deliver が **「Waiting for the build to show up in the build list」ループから抜けられずハングする**ことがある（既存 build は ASC 上に存在するのに API 選択が回らない。v1.44.0 で発生）。数分待って進まなければ **ASC UI から該当 build を手動で「審査へ提出」する方が速い**（1分程度）。macOS の pkg は最後にビルドしたものが残るため、iOS の ipa 再生成で `flutter clean` する前に macOS の submit を先に済ませること。
>
> ⚠️ **fastlane の出力を `| tail` 等にパイプしない**。パイプすると `$?` がパイプ末尾コマンド（tail）の exit code になり、**fastlane の失敗を取りこぼす**。ログはファイルにリダイレクトし（`fastlane release > log 2>&1; echo $?`）、exit code を明示確認すること。
>
> ⚠️ **`fastlane release`（Android）は内部トラックの「現在の」リリースを製品版へ promote する**ため、自分の `fastlane internal` アップロードが失敗していると、トラックに残っている**別ビルドを誤って昇格**しうる。とくに**複数端末で並行ビルドすると versionCode が衝突**し（Google Play は同一トラックの versionCode 重複を拒否）、後発の upload が失敗→既存ビルドが promote される事故が起きる。v1.35.0 で実際に「マージン調整前の 102」が製品版に出た（`| tail` で upload 失敗を見落とし）。**対策**: (1) build 後に実バイナリで versionCode と secrets を確認、(2) 昇格後に Play API で production の versionCode が意図どおりか確認する（手順は §4.4 の Play 版確認、または ASC 同様の service-account JWT で `edits.tracks.get`）。衝突時は `flutter build appbundle --build-number=<次番号>` で採番し直して再 upload→再 promote。

#### サポーター（投げ銭）IAP の審査ノート（[#428](https://github.com/pooza/capsicum/issues/428)、v1.27〜）

消耗型サポータープランを含むビルドを iOS / Android に提出する際は、App Review Information の Notes（App Store）／アプリのアクセス権の説明（Google Play）に [supporter-subscription-plan.md](../../../docs/supporter-subscription-plan.md) C-2 の英文を貼り付ける。機能差別化なし・装飾のみ・単発である旨を明示することで、機能アンロックを伴わない IAP に対する審査員の混乱を回避する。継続課金ではないため Apple Guideline 3.1.2（継続的価値）の論点は発生しない。

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

