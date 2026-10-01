# 開発環境・検証端末

開発マシン・実機検証端末・Android エミュレータのセットアップに関するメモ。個人環境前提のため、他マシンに移行する際の参照用。

## 対応 OS

メインの開発ホストは **macOS**。Apple toolchain（Xcode / fastlane / 各種証明書 / `.p8` 鍵）と Android toolchain・Sentry dSYM アップロード環境がここに揃っており、リリースサイクルおよび iOS / Android / macOS 向けビルドはすべてこのマシンで行う。

v1.24（[CLAUDE.md](CLAUDE.md#デスクトップ対応) のデスクトップ対応 第3段階）以降は Linux / Windows を **補助機**として併用する。Flutter のデスクトップビルドは `flutter build linux` / `flutter build windows` ともクロスコンパイル不可で、配布パイプライン（[#423](https://github.com/pooza/capsicum/issues/423) / [#424](https://github.com/pooza/capsicum/issues/424)）と実機検証（[#425](https://github.com/pooza/capsicum/issues/425)）はそれぞれの OS でしか進められないため。補助機は OS 固有作業（Linux/Windows ビルド・配布物生成・実機検証）専用で、リリース判定・ストア公開・各種シークレット管理はメインの macOS に集約する。

## Flutter SDK のバージョン固定

**全開発機・CI で同一の Flutter stable 版を使う**（現在 **3.44.6**）。版が揃っていないと `flutter pub get` のたびに `pubspec.lock` が書き換わり（SDK 同梱の `meta` / `test` / `test_api` / `test_core`）、端末間で ping-pong する（[#836](https://github.com/pooza/capsicum/issues/836)）。

- CI 側の正本は `.github/workflows/` の `flutter-version`（analyze.yml / linux-release.yml / windows-release.yml の 3 箇所。**必ず 3 つ同時に更新する**）
- 開発機は Flutter SDK の clone で `git checkout <version>` して揃える
- 版を上げるときは CI 3 ファイル + `pubspec.lock` を同一コミットで更新し、全端末を追従させる

確認手順（セッション開始時に毎回回す）は [sync-procedure.md](sync-procedure.md) のステップ 2 にある。

### 基準版に追従する（各端末で普段やる方）

```sh
cd <Flutter SDK の clone>     # 例: /opt/flutter
git fetch --tags origin
git checkout <基準版>          # 例: 3.44.6
flutter --version              # ここで bootstrap が走る

cd <capsicum>
dart run melos bootstrap
```

罠:

- **揃える前に出た `pubspec.lock` の差分はコミットしない。** 版が合っていない状態で `pub get` した結果であり、コミットすると [#836](https://github.com/pooza/capsicum/issues/836) の ping-pong が再発する
- SDK が git clone でない配置（snap / scoop / パッケージマネージャ経由）だと `git checkout` で版を動かせない。その場合は **clone 方式に置き換える**。バージョンを宣言的に固定できることが、この運用の前提
- `flutter --version` を一度通すまで SDK の bootstrap が走らないため、`dart` コマンドの版も古いままになる

### 基準版を上げる（年に数回・1 端末で代表して）

1. SDK を新版に切り替える（上と同じ手順）
2. **CI 3 ファイルの `flutter-version` と `pubspec.lock` を同一コミットで更新する**（`analyze.yml` / `linux-release.yml` / `windows-release.yml`。1 つでも漏らすと CI 内で版が割れる）
3. `flutter analyze` / 全パッケージのテスト / 各 OS のビルドを通す
4. deprecation の移行を同じコミットに含める
5. 他の端末は「基準版に追従する」で追いつく

実例は #836（3.41.9 → 3.44.6）のコミット 2 本がそのまま雛形になる。**iOS / macOS のビルド構成に影響する変更（3.44 の SwiftPM 移行など）を含む場合は、製品版昇格前に内部ベータで検証すること。**

## Xcode の版は pin していない（Flutter と違って勝手に動く）

⚠⚠ **`flutter-version` は CI 3 本と全端末で pin してあるが、Xcode は pin していない。**この非対称が定期的に事故を起こす。

⚠⚠ **CI は iOS / macOS をビルドしない。**Apple 向けビルドは Mac でしか走らないので、**Xcode 由来の破損は手元でしか捕まらない**。リリース当日に初めて気づく経路が実在する。

### 自動更新は止めてある（2026-09-17）

```sh
defaults write com.apple.commerce AutoUpdate -bool false   # 戻すなら -bool true
```

⚠ **App Store アプリ全体に効く**（Xcode だけを対象にする設定は無い）。⚠ **macOS 自体の自動更新は切っていない**（`AutomaticallyInstallMacOSUpdates = 1`）—— 入るのはマイナー / セキュリティ更新で、メジャーは明示同意なしには入らないため。

### Xcode を上げたら、その場でスモークビルドを 1 本通す

```sh
cd packages/capsicum
source ~/.config/capsicum/secrets.env
flutter build ipa --release --dart-define=SENTRY_DSN=$SENTRY_DSN --dart-define=SENTRY_ENV=production --dart-define=RELAY_SECRET=$RELAY_SECRET
flutter build macos --release --dart-define=...   # 同上
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release \
  -archivePath build/macos/capsicum.xcarchive -allowProvisioningUpdates archive
```

⚠⚠ **`flutter build ipa` は失敗しても exit 0 を返すことがある**（2026-09-17 実測）。**終了コードを信用せず、成果物の存在で判定する**:

```sh
ls -la build/ios/ipa/*.ipa
```

⚠ **リリース直後に上げる**のが良い。壊れても次のリリースまでの時間がそのまま復旧の余裕になる。

### 2026-09-17 に Xcode 26 → 27 で踏んだ 3 つ（層が全部違う）

⚠⚠ **1 つ直すと次が出る。**「1 つ直ったから大丈夫」と判断しないこと。

| # | 症状 | 層 | 対処 |
| --- | --- | --- | --- |
| 1 | `Target Integrity: ... IPHONEOS_DEPLOYMENT_TARGET is set to 9.0, but the range of supported deployment target versions is 15.0 to 27.0.x` | **依存（podspec）** | iOS の `Podfile` の `post_install` で 15.0 未満を底上げ |
| 2 | `Binary ... does not contain architectures "arm64 x86_64"` | **Flutter ツール（上流バグ）** | `/opt/flutter` へローカル patch（下記） |
| 3 | `The macOS deployment target ... is set to 11.5, but the range of supported deployment target versions is 12.0 to 27.0.x`（**`Runner` 本体・ShareExtension・NSE**） | **アプリ本体** | **最低 macOS を 12.0 へ引き上げ**（製品判断・pooza 承認） |

⚠ **1 と 3 は同じ形だが深刻度が違う。**1 は依存を宣言済みの値に揃えるだけだが、**3 はサポート対象 OS を切る話**なので製品判断が要る。

⚠ **`Podfile` の `platform` は podspec が明示した値を上書きしない。**Flutter 標準の `flutter_additional_ios_build_settings` は **12.0 未満しか底上げしない**ので、13.0 を宣言しているもの（`flutter_web_auth_2`）は素通りする。

### `/opt/flutter` にローカル patch がある（flutter/flutter#188461）

⚠⚠ **Xcode 27 の `lipo` は `-verify_arch` に複数アーキテクチャを渡せない**（`lipo: -verify_arch requires exactly one input file` を出して exit 1）。Flutter 3.44.6 は 1 回でまとめて渡すため、**バイナリに両方揃っていても失敗する**。

```
packages/flutter_tools/lib/src/build_system/targets/darwin.dart  # thinFramework
```

⚠⚠ **エラーメッセージが実態と逆**（`does not contain architectures "arm64 x86_64"` と出るが、`lipo -info` は両方あると出す）。**patch が消えたときの手掛かりはこの文言**。

⚠⚠ **patch を当てただけでは効かない。**`flutter_tools` はコンパイル済み snapshot として動き、**`.stamp` が一致していると再生成されない**。必ず落とす:

```sh
rm -f /opt/flutter/bin/cache/flutter_tools.{stamp,snapshot}
flutter --version    # ここで Building flutter tool... が走れば再生成された
```

⚠ **これは紛らわしい失敗**。patch はファイルに残っているので `grep` では確認できてしまい、「当てたのに直らない＝patch が違う」と誤診する。実際には**当てたものが使われていない**。

⚠ **消える経路**: `git checkout`（＝[基準版に追従する](#基準版に追従する各端末で普段やる方)の手順そのもの）/ SDK 入れ直し / 別の Mac には**最初から当たっていない**。

⚠ **上流が修正したら patch を外して正規の版へ戻す。**判断は [flutter-upstream-watch.md](flutter-upstream-watch.md) の監視対象テーブルで追う。

## Debug ビルドと TestFlight の役割分担

Debug ビルドは「コードを動かしてみるための環境」であり、本番相当の検証は TestFlight / 内部テストトラックで行う。Debug 環境で本番と同じ機能スイートが揃わなくても、TestFlight 経由で検証できるなら気にしない方針。

具体例:

- **App Group / Keychain Access Group**: Debug ビルドは Release と同じ App Group ID (`group.jp.co.b-shock.capsicum`) と keychain-access-groups を共有しているため、Debug で動かした capsicum が ShareExtension 用 App Group コンテナへ書いたファイルを Release インスタンスが読む経路ができる ([#504](https://github.com/pooza/capsicum/issues/504))。本来は Debug 用に別 App Group ID (`group.jp.co.b-shock.capsicum.debug`) を分離すべきだが、開発機限定で同居する debug + release のクロス参照は実害が薄く、Xcode / Apple Developer Portal 側の provisioning 作業コストに見合わない。TestFlight 経由の検証で sandbox 境界の挙動は担保される
- **macOS Debug の sandbox オフ**: ad-hoc 署名 + sandbox の組み合わせで ASWebAuthenticationSession / Keychain (`flutter_secure_storage`) が `errSecMissingEntitlement` (-34018) で動かないため、Debug は `com.apple.security.app-sandbox=false` で運用している。これも sandbox 挙動の検証は TestFlight で行う前提で運用ルール化されている
- **APNs / FCM の実配送**: OS ネイティブの受信経路が絡むケース（entitlements / NSE / bg task 等）は Debug では検証成立しないため、TestFlight / 内部ベータ経由で検証する

判断ルール: 「Debug で再現しないからどうにかしたい」となったら、まず **TestFlight 経由で検証する経路があるか** を確認する。あるなら Debug を本番並みに引き上げるコストはかけない。

⚠ ただし **dart-define 機密値は「Debug では成立しない」ものではない**。`RELAY_SECRET` を渡せば Debug ビルドも staging relay に登録でき、プッシュ登録までは Debug で確かめられる（[#948](https://github.com/pooza/capsicum/issues/948) が debug の向け先を staging にしたのはそのため）。渡し方は次節。

## `flutter run` の実行手順

**普段は `tool/dev-run.sh`（Windows は `tool/dev-run.ps1`）を使う**（[#1179](https://github.com/pooza/capsicum/issues/1179)）。`secrets.env` の読み込み → `build_runner` → `packages/capsicum` で `flutter run --dart-define=RELAY_SECRET=...` までを 1 本で回し、下の罠を踏まない。`-d` などの残りの引数は `flutter run` へそのまま渡る。

```sh
tool/dev-run.sh -d macos          # build_runner から
tool/dev-run.sh -s -d macos       # build_runner を飛ばす
tool/dev-run.sh -n -d macos       # 流すコマンドを表示するだけ（秘密は伏せる）
```

```powershell
powershell -ExecutionPolicy Bypass -File tool\dev-run.ps1 -d windows
powershell -ExecutionPolicy Bypass -File tool\dev-run.ps1 -SkipBuildRunner -d windows
```

オプションの一覧（sh / ps1 の対応・`--dry-run` / `-DryRun` を含む）と、Windows 版の自前オプションが**完全一致だけ**である理由は [tool/README.md](../tool/README.md) にある（[#1192](https://github.com/pooza/capsicum/issues/1192)）。⚠ Windows 版は melos を通さず、`build_runner` に依存するパッケージで直接 `dart run build_runner build` する（下の Windows 節の注記と同じ理由）。

中でやっていることは次の手順と同じ。

```sh
source ~/.config/capsicum/secrets.env
cd packages/capsicum
flutter run -d <device-id> --dart-define=RELAY_SECRET=$RELAY_SECRET
```

### `secrets.env` を置く（メンテナ向け・[#1180](https://github.com/pooza/capsicum/issues/1180)）

スクリプトもこの手順書も `~/.config/capsicum/secrets.env`（Windows は `%USERPROFILE%\.config\capsicum\secrets.env`）を読む。中身は sh の書式:

```sh
export RELAY_SECRET=...
export SENTRY_DSN=...
```

- ⚠ **値そのものは公開リポジトリに書かない。**メンテナは共有ドライブから取る（メイン機では Google ドライブ上の実体への symlink で置いてある）
- **debug で要るのは `RELAY_SECRET` だけ。**`SENTRY_DSN` はリリースビルドでしか使わない
- ⚠ Windows 版スクリプトも**同じ sh 書式のファイル**を読む（`export` の有無とクォートは吸収する）
- 置き場所を変えたいときは環境変数 `CAPSICUM_SECRETS` でファイルを指せる

### 置かなくても動く（何が使えなくなるかだけ変わる）

⚠⚠ **秘密を持てるのはメンテナだけなので、どれも「無いと止まる」にしない**（#1180）。無ければ警告を出して起動し、**使えなくなるのはプッシュ通知だけ**に揃えてある。

| 置かないもの | 起動 | 使えなくなるもの |
| --- | --- | --- |
| `RELAY_SECRET` | する | **プッシュ通知だけ。**登録が 401 で落ちる（設定 → プッシュ通知に 401 と出る）。タイムライン・投稿などは影響なし |
| `SENTRY_DSN` | する | クラッシュ報告が送られない。⚠ **debug ではもともと渡さない**ので、開発では差が無い |
| `packages/capsicum/android/app/google-services.json` | する | **プッシュ通知だけ**（Android）。⚠ `.gitignore` で除外されているので、外部の開発者は持てない |

- ⚠ **`google-services.json` は 2026-09-29 まで「無いとビルドごと落ちる」だった。**`android/app/build.gradle.kts` が `com.google.gms.google-services` を無条件に適用しており、`:app:processDebugGoogleServices` で失敗していた。**ファイルがあるときだけ `apply(plugin = ...)` する**形に変えて、上の表の他の行と揃えた
- ⚠ 実行時に困らないのは、`_initFirebase()` が例外を握って rethrow しないため。**プラグインが無い ＝ プッシュ通知だけ使えない**に収まる

### `--dart-define` を省くとプッシュが 401 で落ちる

⚠ `RELAY_SECRET` は `String.fromEnvironment` で読む **コンパイル時定数**（[`push_relay_client.dart`](../packages/capsicum/lib/src/service/push_relay_client.dart)）。**`secrets.env` を `source` して `export` しても Dart には届かない。**`--dart-define` で渡さないと空文字が焼き込まれ、relay の `authenticate!` が `halt 401` する。

症状の見え方:

- 端末: 設定 → プッシュ通知 の各アカウントが **401**
- relay: **何も残らない**。401 はログを 1 行も出さない（[capsicum-relay#47](https://github.com/pooza/capsicum-relay/issues/47)）。サーバー側の journald が空なのを見て「リクエストが届いていない」と誤診しやすい

⚠ **`export` 文と `flutter run` 文は必ず別の行にする。** `RELAY_SECRET="..." flutter run ...` と 1 行に前置すると `$RELAY_SECRET` は**親シェルで空に展開される**。同じ罠を release ビルドで踏んで `v1.21.0+50` の全アカウント push 不達を起こしている（[store-release スキル](../.claude/skills/store-release/build-upload.md) §4.2）。2026-08-18 には run 側で同じことが起き、「debug 版でプッシュ通知を見たことがない」という長期の状態になっていた（[#994](https://github.com/pooza/capsicum/issues/994)）。

`SENTRY_DSN` は debug では**渡さない**のが既定。渡すと開発中の例外が本番プロジェクトへ流れる。

### リポジトリ root では iOS がデバイス候補に出ない

⚠ `flutter run` は**カレントのプロジェクトが対応するプラットフォームだけ**を候補に出す。リポジトリ root は melos の workspace（`name: capsicum_workspace`）で `ios/` も `macos/` も持たないため、**シミュレータを起動していても iOS が候補から落ちる**。

`flutter devices` は絞り込まずに全部並べるので、**「`flutter devices` には出るのに `flutter run` で選べない」**という食い違いが起きる。`packages/capsicum` へ `cd` してから実行する。

## 課金 UI をストアなしで出す（StoreKit Configuration・#1122）

`packages/capsicum/ios/Capsicum.storekit` に**ローカルの商品定義**がある。Xcode で有効にすると、**App Store Connect の状態に関係なく**購入 UI が出る。

⚠⚠ **要るのは「審査用スクリーンショット」を撮るため。**App Store Connect のサブスクは商品ごとにこれを要求するが、⚠ **`MISSING_METADATA` のあいだ StoreKit は商品を返さない**ので、アプリ側の購入節は丸ごと隠れる（「押しても買えない入口を作らない」作り）。**鶏と卵になるのをこれで外す。**

**有効にする**: Xcode → Product → Scheme → Edit Scheme → Run → Options → **StoreKit Configuration** に `Capsicum.storekit` を選ぶ。

⚠ **共有スキーム（`Runner.xcscheme`）には入れていない。**入れると debug ビルドが常にローカル商品を使い、⚠⚠ **サンドボックスの実購入を一度も踏まないまま出荷しうる**。**撮るときだけ手で選ぶ。**

### 🔴 これで購入しても「動いた」ことにはならない

| | |
| --- | --- |
| 出るもの | ✅ 商品名・価格・購入シート（**見た目は本物と同じ**） |
| 出ないもの | 🔴 **ストアの本物のレシート** |

⚠⚠ **relay の `POST /entitlements` は偽の `purchase_id` を受け取る**ので、App Store Server API の検証が通らず **`unverified` のまま**になる。**「購入 → 利用権が有効」の実測にはならない。**それはサンドボックス（本物の Apple ID のテスター）でやる。

⚠ **投げ銭 3 種もこのファイルに入れてある。**StoreKit Configuration を有効にすると**そのファイルにある商品しか返らない**ので、抜くと投げ銭の節が消えて**画面が本番と違う形で写る**。

## Claude Code の権限設定（auto モード・全端末）

**目標は「本番サーバーを壊す操作でない限り確認 0」。**確認が出たら、その場でクリックして流すのではなく**設定を直して次から出ないようにする**。定形作業（同期・リリース・デプロイ）の途中でダイアログが連発するのは、たいてい手順書のコマンドが使う補助コマンドが allowlist に無いだけなので、1 つずつ足すのではなく**手順書を読み直してまとめて 1 回で足す**。

### 何をどちらのファイルに書くか

| | ファイル | git | 中身 |
|---|---|---|---|
| モード | `.claude/settings.json` | tracked | `permissions.defaultMode` = `auto`。全端末共通なのでここでよい |
| 汎用 permission | `.claude/settings.json` | tracked | ホスト名・絶対パスを含まないもの（`git -C * show *` 等） |
| 端末固有 permission | `.claude/settings.local.json` | **gitignore** | 内部ホスト名を含む ssh / scp、端末固有の絶対パス |
| `autoMode` ブロック | `.claude/settings.local.json` | **gitignore** | 本番・ステージングの固有名が文面に入るため |

⚠ **capsicum は public リポジトリ。**内部 SSH ホスト名・deploy ユーザー名を含むものは `settings.json` に書けない。`autoMode` の文面は本番 4 台・ステージング 4 台・relay 2 台の名前を含むので、**必ず `settings.local.json` 側**に置く。

⚠ **`acceptEdits` では Bash の確認は 1 件も減らない。**自動承認されるのはファイル編集だけで、確認の発生源はほぼ全部 Bash 側。逆に `bypassPermissions` は本番への操作まで素通りするので使わない。

### `autoMode` の書き方

自然文で意図を書く。permission パターンは URL を判定できないが、分類器は文意を読む。**`curl` を規約でしか止められなかった問題は、これで設定側へ移せる。**

- `soft_deny`（＝確認へ落とす）: 本番 Fediverse サーバー 5 つの**状態を変える操作**（書き込み API・`tootctl` 等の管理コマンド・本番 DB への書き込み）と、本番ホスト上でサービス / DB の状態を変える操作。**読み取り（GET）は入れない**
- `allow`: 本番およびモロヘイヤへの**読み取り**、ステージングへの読み書き、capsicum-relay 本番への読み取り / デプロイ / 再起動、GitHub と Sentry の操作、ローカル git とビルド / テスト / 解析

⚠ **配列の先頭に `"$defaults"` を入れる。**`autoMode.allow` / `soft_deny` / `environment` は**書いた内容で組み込みルールを置き換える**ため、入れないと組み込みが消える（Claude Code 2.1.x）。

⚠ **`hard_deny` は本番 Fedi に使わない。**明示的に指示されたときは確認の上で実行したいので、`soft_deny`（確認へ落とす）が正しい。

固有名の出典（**この docs には書かない**）:

- プリセット 5 サーバーのドメイン → `packages/capsicum/lib/src/preset_servers.dart`
- 本番 4 台・ステージング 4 台・relay 2 台のホスト名とユーザー → chubo2 `docs/infra-servers.md` の「本番」節
- ⚠ chubo2 の `docs/infra-note.md` は 2026-08-23 に 10 ファイルへ分割された。サーバー一覧は `infra-servers.md` を見る

### `permissions.allow` の ssh は別枠

`autoMode` を整えても、`permissions.allow` に ssh のエントリが無ければ確認が出る。**relay 2 台とステージング 4 台は allow に入れる。**

⚠ **本番 4 台はあえて `allow` に入れない。**allowlist に入ると分類器を素通りし、`soft_deny` が効かなくなる。読み取り目的の ssh でも分類器に通す。そのうえで **`permissions.ask` に本番 4 台を FQDN で明示**しておくと、表記ゆれに関係なく確実に確認へ落ちる。

⚠ **本番ホストは FQDN で書く。**`~/.ssh/config` は chubo2 の workstation レシピが自動生成し、**旧来の親しみやすい別名（`<サービス名>_<用途>` 形式）は廃止**されて Host は FQDN になっている。別名で書いたエントリは、移行済みの旧ホストを指したまま**永久に一致しない**死に設定になる。実際、キュアスタ！とダイスキーは 2026-07〜08 に別ホストへ移行しており、別名のまま残った設定は現行ホストに当たらない。

### 落とし穴

- ⚠ **絶対パスは素の名前の allowlist に当たらない。**`Bash(sentry-cli *)` は `~/.local/bin/sentry-cli` を通さない。素の名前で呼べない端末では実パスを `settings.local.json` に足す
- ⚠ **`ssh -o ConnectTimeout=10 user@host …` は `Bash(ssh user@host *)` に当たらない。**オプションが先に来るため。`Bash(ssh -o * user@host *)` を対で入れる
- ⚠ **`scp` の `:*` はパターン末尾にしか置けない。**アップロードは `Bash(scp * user@host:*)`、ダウンロードは `Bash(scp user@host:*)`
- ⚠ **auto モードの分類器は「広い」自己付与を拒否する。**ホスト限定の ssh エントリは通るが、`git -C <path> *`（任意のサブコマンド）や `curl -s -X *`（任意の HTTP メソッド）は**確認にもならず拒否**される。迂回せず、一時的に手動モードへ戻してもらうか、ホスト・パスを固定した狭いエントリに割る
- ⚠⚠ **認証情報を画面へ読み出す手順は、auto モードでは通らない前提で組む。**同期スキル §7 の旧手順（`awk '/\[auth\]/{getline; print}' ~/.sentryclirc | sed 's/token=//'` でトークンを出し、`curl` へ埋める）は、**分類器が「Credential Materialization」として拒否する**（2026-09-08 に Linux 端末で実測。`sed -n '1,10p' ~/.sentryclirc` も同じ）。⚠ **コマンドの形の問題ではないので、下の「コマンドの書き方」に沿っても抜けられない**
  - ⚠⚠ **`autoMode.allow` に自然文で許可を書いても止まる。**2026-09-08 は文面を足して通ったが、**2026-09-17 に同じ文面が入った端末で再び拒否された**（`Bash(awk *)` / `Bash(sed *)` が `permissions.allow` にあっても同じ）。文意で通るかは分類器の判断次第で、当てにできない
  - **直し方は、読み出しをスクリプトの中へ閉じること。**[`.claude/scripts/sentry-api.sh`](../.claude/scripts/sentry-api.sh) が `~/.sentryclirc` を自分で読み、`curl -K -`（標準入力）と `SENTRY_AUTH_TOKEN` でだけ渡す。**トークンが会話にもプロセスの引数にも出ない**ので、拒否の理由そのものが無くなる。`settings.json` の `Bash(.claude/scripts/sentry-api.sh *)` で許可している（tracked・全端末共通なので端末ごとの追記は要らない）。送り先は `https://sentry.io/api/0` に固定で、呼ぶ側から変えられない
  - ⚠ **`Bash(awk *)` を足して塞ごうとしないこと** — `awk` は任意コード実行なので、`python3 -c` を allowlist に載せない方針と同じ理由で載せてはいけない
  - 使い方は同期スキル §7（`get <path>` / `post <path> <json>` / `cli <sentry-cli の引数>`）

シェルのループと関数定義を機械的に拒否する `PreToolUse` フックについては、下の「ループと関数定義は機械で止めている」を参照。

## コマンドの書き方（許可確認を出さないための約束）

⚠ **定形作業（同期・リリース・デプロイ）は、許可確認 0 回で完走できる書き方に揃える。**2026-08-25 の同期で 10 回以上の確認を出して指摘を受けた。原因は allowlist の穴ではなく**コマンドの形**だったので、規約として置く。

上の「Claude Code の権限設定」が**端末側の設定**の正本で、こちらが**書き方**。**書き方を守っても設定が無ければ確認は消えない**ので、新しい端末に着いたら設定を先に済ませる。

⚠⚠ **ここは場面を問わず効く常時ルール。**2026-09-13 まで `sync-procedure.md` の §0 に置いてあったが、**同期のときしか読まれない場所に常時ルールが埋まっていた**（#1114 の棚卸しで、`cd` の規約を同じセッション中に 2 回破った実例が出た）。同期以外の作業でも同じ穴を踏むので、手順書から出して端末側の規約と並べた。

| やらない | 代わりに |
| --- | --- |
| `python3 -c` / `perl -e` で JSON を捌く | **`jq`**。インタプリタは任意コード実行になるので allowlist に載せない方針で、載る見込みもない。⚠ **フックで拒否する**（下の「インタプリタは書き方で分ける」節） |
| **シェルの `for` ループで複数対象を回す** | **1 対象 1 ツール呼び出しにして並列に投げる**。ループは丸ごと未知のコマンド扱いになる。並列のほうが速い |
| 関数定義・`$(...)`・`while` 等をコマンドに混ぜる | 同上。**複合シェル構文が 1 つでも入ると、中身が全部 allowlist に載っていても確認になる** |
| 他リポジトリへ `cd` してから `git` | **`git -C <path> <sub>`**。許可済みは `fetch` / `log` / `pull` / `status` / `tag` / `show` / `diff` / `rev-parse` / `rev-list` / `branch` / `describe` の 11 個。⚠⚠ **`cd` は次のツール呼び出しにも残る**（下の「`cd` は残る」節） |
| `gh` をリポジトリ指定なしで書き込む | **`gh <sub> --repo pooza/capsicum`**。⚠ **書き込み系（`issue comment` / `issue create` / `issue edit` / `pr comment`）は必ず付ける。**読み取りだけなら省略してよい |
| 絶対パスでコマンドを呼ぶ | **素の名前で呼ぶ**。`Bash(sentry-cli *)` は `/Users/…/.local/bin/sentry-cli` には**当たらない**（別コマンド扱い）。絶対パスが要る環境では settings.local.json に実パスで足す |
| `curl -sL` / `curl -sX` のように短縮を連結 | **`curl -s -L` / `curl -s -X`**。allowlist は `curl -s ` の後ろに空白を要求する |
| `TOKEN=$(...)` の変数代入から始める | トークンは**単独のコマンドで 1 回読んで**、以降のコマンドへ直接埋める |
| `pgrep -f <パターン>` / `pkill -f <パターン>` をそのまま叩く | **`ps -u "$(id -u)" -o pid=,cmd=` + `grep '[p]attern'`**（bracket trick）。⚠⚠ **`-f` は全コマンドラインを見るので、そのパターン文字列を含む自分のシェルにも一致する** —— `pgrep` は毎回違う PID を返して「プロセスが増殖している」ように見え、`pkill` は**自分を殺す**（2026-09-13 に両方踏んだ）。対象を絞るときは**プロセス名（`pgrep -x`）と併せて二重に**当てる。⚠ `comm` は **15 文字で切り詰められる**（`gnome-keyring-daemon` は `gnome-keyring-d`）ので、`-x` には切り詰め後の名前を渡す |

### インタプリタは「書き方」で分ける（禁止ではない）

⚠⚠ **禁じているのは「Python を使うこと」ではなく「Python に逃げること」。**
`.claude/hooks/deny-interpreter-inline.sh` が **PreToolUse で機械的に弾く**
（2026-09-28 に規約化。⚠ **2026-08-23 / 08-25 / 09-28 と 3 度破られた**ため、
読んで守る仕組みから外した）。

| 形 | 扱い |
| --- | --- |
| `python3 -c '...'` / `perl -e` / `ruby -e` / `node -e` | 🔴 **フックが拒否** |
| `python3 - <<'PY'` / `python3 <<PY` | 🔴 **拒否**（コードが会話に残らない） |
| `curl ... \| python3 -m json.tool` | 🔴 **拒否**（`jq` で書く） |
| ✅ `python3 tool/foo.py` / `bundle exec ruby /tmp/probe.rb` | **通る** |
| ✅ `bundle exec ruby -Ilib -Itest test/foo_test.rb` | **通る**（`-e` が無いオプション列は当たらない） |

#### 例外の判定基準

「Python のほうが**楽か**」ではなく、

> ⚠⚠ **jq / Edit では *そもそも書けない* か**

で判定する。書けるなら使わない。⚠ **複数行にまたがる置換は「書けない」に当たらない**
——**そこは Edit ツールの出番**（この取り違えが 3 度の違反すべての原因だった）。

本当に要る例:

- 複数ファイルの横断解析・集計（jq で組めない join / 統計）
- バイナリ・エンコーディングの検査（DER / base64 / 証明書の中身）
- 使い捨ての検証スクリプト（例: 2026-09-28 の `vapid_probe.rb` —— 生の P-256
  公開鍵から ES256 の検証鍵を組めるかを実測した）

#### 使うときはスクリプトにする

⚠ **Write でスクラッチパッドに書いてから実行する。**

- **コードが差分として会話に残る**ので、何をしたか後から読める
- ⚠ 許可確認が「**不透明な 1 行**」ではなく「**レビューできる 1 本**」に対して出る

⚠ **確認は出る**（`python3 *` は allowlist に載せない方針）。そのぶん、**出る回数を
例外の回数に抑える**のがこの規約の狙い。

### 検査コマンドをパイプに繋がない（exit code が消える）

⚠⚠ **2026-09-19 に、`dart analyze` の失敗を見落としたままコミットした**（push 前に気づいて直した）。

```sh
# ⚠ これは常に成功する。パイプラインの exit code は最後の tail のもの
dart analyze packages 2>&1 | tail -2 && git commit ...
```

⚠⚠ **CI は `dart analyze --fatal-infos` なので、info 1 件でも赤になる。**このときは `unnecessary_brace_in_string_interps` が 3 件出ていたが、`| tail -2` で握り潰されて `git commit` まで通った。

- **合否を見るコマンドは、そのまま実行する**（出力が長くても `tail` に繋がない）。長さが気になるなら `dart analyze packages; echo "exit=$?"` のように**終了コードを明示的に出す**
- ⚠ **`&&` で後続に繋ぐときは特に危ない。**「検査 → コミット」を 1 行にすると、検査が実質無効になっていても気づけない
- ⚠ `flutter test` も同じ。**`| tail -3` で「All tests passed!」だけを見る書き方は、失敗時に行が流れて見落とす**ので、失敗の有無は終了コードで確かめる

### `cd` は次のツール呼び出しにも残る（外部リポジトリへの誤爆を起こした）

⚠⚠ **2026-09-04 に、上流の `mastodon/mastodon` へコメントを投稿する誤爆を起こした。**約 1 分で削除したが、**公開リポジトリに他プロジェクトのメモが載った**。

経緯:

1. フォークを調べるため `cd /Volumes/extdata/repos/mastodon && git diff ...` を実行した（**この時点で `git -C` の規約に違反**）
2. Bash ツールの **working directory はツール呼び出しをまたいで持続する**
3. 数手あとに `gh issue comment 1054 --body ...` を実行 → **`gh` は cwd の git remote を見る**ので `mastodon/mastodon` の #1054（無関係な PR）へ飛んだ

⚠ **`git -C` の規約は許可確認を減らす目的で書かれていたが、この誤爆も防いでいた。**規約を守っていれば起きなかった。

したがって二重化する:

- **他リポジトリを読むときは `git -C <path>`。`cd` しない**
- **`gh` の書き込み系は `--repo pooza/capsicum` を必ず付ける。**cwd が正しいと信じない
- ⚠ **番号の衝突は日常的に起きる。**capsicum の #1054 は mastodon/mastodon にも存在した。**「番号が通ったから正しいリポジトリ」ではない**

削除は `gh api -X DELETE repos/<owner>/<repo>/issues/comments/<id>`。実行後に同じ ID を GET して **404 を確認する**。

### ループと関数定義は機械で止めている

⚠⚠ **この規約を書いた翌セッション（2026-08-25）に、筆者自身が `for` ループを 3 回使って確認を出した。**「読めば守れる」規約ではないと判断し、**ハーネス側の拒否に移した**。

- 実体: [`.claude/hooks/deny-shell-loops.sh`](../.claude/hooks/deny-shell-loops.sh)（`PreToolUse` / matcher `Bash`）
- 拒否するのは **`for` / `while` / `until` ループと関数定義**のみ。**コマンド置換 `$(...)` は塞いでいない** — `git commit -m "$(cat <<'EOF' …)"` が標準のコミット手順で、塞ぐとコミットが打てなくなるため
- 誤爆しないよう、**ループ header の形（`; do` / 行頭 `do`）と `done` の両方が揃った場合のみ**拒否する。`for` と `done` を含むだけの散文（コミットメッセージ等）は通る
- **heredoc の本文は検査しない。**区切り語までの中身を落としてから判定する。`cat > f <<'EOF'` でコードを流し込むと、Dart / JS / Swift 等の `void dispose() {` が関数定義パターンに一致して**コードの書き出しが軒並み拒否される**ため（2026-08-25 に実際に踏んだ）。本文の後ろに本物のループが続く場合はそちらを拾う
- 入力が壊れていたら**フェイルオープン**（通す）。ガードが Bash 全体を止めないため

⚠ そもそも**コードファイルの作成・編集は Bash ではなく Write / Edit ツールで行う**。ヒアドキュメントでの書き出しは差分が見えず、上のような誤爆も呼ぶ。

拒否されたら、その場で **1 対象 1 呼び出し × 並列**に展開し直す。**ここを回避する書き方を探さないこと**（規約を機械化した意味が消える）。

`curl` の出力から本文を抜くときは `jq -r` で必要なフィールドだけ取り出す（HTML タグを落としたいだけなら `sed 's/<[^>]*>//g'`）。

例外は**動画・画像の検証**（`ffmpeg` でのフレーム抽出等）。これは定形ではないので確認が出てよい。

## メイン (macOS) セットアップ

- `~/.config/capsicum/` に App Store Connect API Key（`.p8`）と Google Play サービスアカウント JSON キーを配置（Fastfile から参照。具体的なファイル名・Key ID 等は非公開）
- `~/.config/capsicum/secrets.env` を Google Drive 上の実体への symlink で配置（`SENTRY_DSN` / `RELAY_SECRET` を複数 PC で共有するため。実体パスは非公開）
- Xcode → Settings → Accounts で Apple ID 追加 → Manage Certificates → Apple Distribution 証明書を作成
- `gem install fastlane`（rbenv の Ruby を使用）
- Android 署名鍵 `android/key.properties` を配置（git 管理外、手動配置）
- リポジトリルートの `.sentryclirc`（git 管理外）に dSYM アップロード用トークンを配置（iOS / macOS の `fastlane upload_dsyms_to_sentry` が呼ぶ `sentry-cli` が親ディレクトリを辿って拾う・#1134）
- `~/.sentryclirc` に Issue 読み取り用トークン（`event:read` / `event:write` / `project:read`）を配置

### 新規の macOS app-extension ターゲット追加後のプロビジョニング（#673）

macOS の Runner に新しい app-extension ターゲット（NSE / ShareExtension 等）を追加した直後は、その bundle id 用の **Mac プロビジョニングプロファイルがまだ生成されていない**ため、`flutter run -d macos` / `flutter build macos` が「No profiles for '…' were found / Automatic signing is disabled and unable to generate a profile」で失敗する。`flutter` は xcodebuild に `-allowProvisioningUpdates` を渡さないため、未署名の新ターゲット用プロファイルをオンザフライで自動生成できないのが原因（App ID 自体は既に存在し App Groups も付与済みで、登録作業は不要なことが多い）。

各 macOS 端末で **一度だけ** プロファイルを生成すれば、以後は `flutter run -d macos` も通る:

```sh
cd packages/capsicum/macos
xcodebuild -allowProvisioningUpdates -workspace Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

Xcode でワークスペースを一度開いて自動署名させてもよい。なお `keychain-access-groups` を `$(AppIdentifierPrefix)group.<App Group id>` の App Group 形式で書く場合、Apple Developer Portal 側に専用の「Keychain Sharing」capability を追加する必要はない（App Groups 配下で動く）。

詳細なリリース手順は [store-release スキル](../.claude/skills/store-release/SKILL.md)（初回セットアップは [store-release-guide.md](store-release-guide.md)）。

## 補助機（Linux / Windows）セットアップ

⚠ **別ファイルにある → [dev-environment-desktop.md](dev-environment-desktop.md)。**system 依存・ツールチェーン・内部ベータの導入経路・ARM / x64 の差・native クラッシュのトリアージ・bg task の実機確認手順はそちら。

**この 2 機でも、上の「[コマンドの書き方](#コマンドの書き方許可確認を出さないための約束)」と「[Claude Code の権限設定](#claude-code-の権限設定auto-モード全端末)」はそのまま効く。**⚠ 端末で拾う作業の探し方（`Windows` / `Linux` ラベル）も同ファイルにある。

## Sentry

- 組織アカウントの Sentry を利用（プロジェクト `capsicum`、有料プラン契約済み。ダッシュボード URL は非公開）
- DSN は公開鍵相当（送信専用）なのでビルドへの埋め込みは問題なし
- 環境切り替え: `--dart-define=SENTRY_ENV=production`（デフォルト `debug`）
- Apple の dSYM: iOS / macOS の `fastlane beta` が TestFlight へ上げる前に `upload_dsyms_to_sentry` レーンで上げる（#1134）。⚠ **`pubspec.yaml` の `sentry: upload_debug_symbols` は `sentry_dart_plugin` の設定で、Apple の dSYM は対象外**（2026-09-21 まで Sentry に dSYM が 0 件で、capsicum 自身のフレームが復元されていなかった）。⚠ `sentry_dart_plugin` は依存に入っているが、`dart run sentry_dart_plugin` を回す手順はどこにも無い（Android の ProGuard マッピング等が上がっているかは未確認）。リポジトリルートの `.sentryclirc`（git 管理外）でトークン管理。環境変数 `SENTRY_AUTH_TOKEN` はプロジェクトごとのトークン使い分けのため使わない

### 活用戦略

ピンポイント方式（問題が起きた箇所・起きやすい箇所に `captureException` を仕込む）。現在の計装:

- `runZonedGuarded` で未処理例外を全捕捉
- ページネーション・WebSocket 等の既知問題箇所にピンポイント送信

次の拡張タイミング: ストア公開後ユーザーが増えた段階でパフォーマンスモニタリング導入を検討。

### Issue 読み取り用トークン

リポジトリ直下の `.sentryclirc` は dSYM アップロード用の `org:ci` スコープのみで、Issue 読み取り不可。進捗同期時は `~/.sentryclirc`（広スコープ、`project:read` あり）のトークンを [`.claude/scripts/sentry-api.sh`](../.claude/scripts/sentry-api.sh) 経由で使う（`cli` サブコマンドがそのプロセスにだけ `SENTRY_AUTH_TOKEN` を渡す。⚠ シェルへ `export` するとプロジェクトごとのトークン使い分けを壊すので、環境変数として常駐させない）。詳細は [sync-procedure.md](sync-procedure.md) の同期手順を参照。

## iOS 実機環境

- 実機接続時は Parallels Desktop を終了させること（Parallels が USB デバイスを横取りするため）
- iOS アップデート後にデベロッパモードがリセットされることがある → 設定 → プライバシーとセキュリティ → デベロッパモード で再有効化

### 画面をコマンドで撮る（シミュレータ / USB 実機）

| 対象 | コマンド |
| --- | --- |
| シミュレータ | `xcrun simctl io <UDID> screenshot /tmp/x.png` |
| USB 実機 | `xcrun devicectl device capture screenshot --device <UDID> --destination /tmp/x.png` |

- ⚠ `devicectl` は **`--destination` が必須**（パス直指定だと `Missing expected argument` になる）
- ⚠⚠ **実機はロックを解除しておく。**ロック中は**エラーにならず真っ黒な PNG が返る**（数十 KB と極端に小さい。中身があれば数百 KB）ので、「撮れていない」ことに気づきにくい
- ⚠ **入力（タップ・スワイプ・テキスト）は送れない。**`devicectl device` に入力系のサブコマンドが無い
- Xcode 27 で `Simulator.app` は `Xcode.app/Contents/Applications/DeviceHub.app` に替わった（GUI の入口が替わっただけで `simctl` は健在）

### iOS シミュレータで書き出したファイルを Mac から読む

共有シート経由でファイルを書き出す機能（設定のバックアップ #972 など）の検証で使う。⚠ **共有シートの「コピー」は macOS の Finder には貼れない。**載せているのはテキストではなく**ファイル**で、iOS のファイル用ペーストボードは Finder と繋がっていないため（シミュレータのクリップボード同期もテキスト用）。中身を Mac で確認したいときはコンテナを直接読む。

```sh
xcrun simctl list devices booted
xcrun simctl get_app_container <UDID> jp.co.b-shock.capsicum.debug data
```

- `<container>/Library/Caches/…` … **アプリが共有前に書いた実体**（`path_provider` の `getTemporaryDirectory` は iOS では Caches に落ちる）
- `<device>/data/Containers/Shared/AppGroup/<id>/File Provider Storage/…` … ファイル.app の「このiPhone内」へ保存した先。同名保存は iOS が `foo 2.yaml` と自動採番する

⚠ **Mac 側へコピーするときは宛先の存在を確かめ、日時入りの別名にする。**既定のファイル名のままデスクトップへ `cp` すると、過去の書き出し（macOS 版で作ったものなど）を黙って上書きしうる。**上書きすると inode が残るため birth time が古いままになり、「これは本当に今コピーしたものか」が後から判別できなくなる**（2026-08-22 に実際に踏んだ）。

⚠ **設定バックアップの YAML にはプラットフォームを示す項目が無い**（`version` / `app_version` / `exported_at` / `settings` のみ）ので、ファイル単体では iOS 由来か macOS 由来かを判別できない。出所を確かめるには上記パスから取るか、**端末側で設定を 1 つ変えて再書き出しし、値と `exported_at` が追随することを見る**。

### シミュレータで確認できないこと

- **iCloud Drive / Google Drive を挟んだ PC との往復** … シミュレータには App Store が無く Drive アプリを入れられない。iCloud はサインイン UI こそ出るが 2FA の確認コードが信頼済みデバイスへ飛び、iCloud Drive の同期も実質動かない。**外部保存先の確認は実機で行う**

## Android エミュレータ環境

- `ANDROID_SDK_ROOT` / `JAVA_HOME` を設定し、`$ANDROID_SDK_ROOT/emulator/emulator -avd <AVD>` でエミュレータを起動（arm64 AVD を使用）

### エミュレータで既知の問題

- カスタムスキーム `capsicum://oauth` のリダイレクトが Android エミュレータで動作しない（OOB 方式で代用中）。[tech-notes.md](tech-notes.md) の認証フロー節も参照

（個々の検証端末・UDID・AVD 名・SDK パスといった端末固有の具体値は、public リポジトリには置かず別途管理する）
