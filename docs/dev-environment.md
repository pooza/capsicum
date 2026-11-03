# 開発環境・検証端末

開発マシン・実機検証端末・Android エミュレータのセットアップに関するメモ。個人環境前提のため、他マシンに移行する際の参照用。

## 対応 OS

メインの開発ホストは **macOS**。Apple toolchain（Xcode / fastlane / 各種証明書 / `.p8` 鍵）と Android toolchain・Sentry dSYM アップロード環境がここに揃っており、リリースサイクルおよび iOS / Android / macOS 向けビルドはすべてこのマシンで行う。

v1.24（[CLAUDE.md](CLAUDE.md#デスクトップ対応) のデスクトップ対応 第3段階）以降は Linux / Windows を **補助機**として併用する。Flutter のデスクトップビルドは `flutter build linux` / `flutter build windows` ともクロスコンパイル不可で、配布パイプライン（[#423](https://github.com/pooza/capsicum/issues/423) / [#424](https://github.com/pooza/capsicum/issues/424)）と実機検証（[#425](https://github.com/pooza/capsicum/issues/425)）はそれぞれの OS でしか進められないため。補助機は OS 固有作業（Linux/Windows ビルド・配布物生成・実機検証）専用で、リリース判定・ストア公開・各種シークレット管理はメインの macOS に集約する。

## Flutter SDK のバージョン固定

**全開発機・CI で同一の Flutter stable 版を使う**（現在 **3.47.9**）。版が揃っていないと `flutter pub get` のたびに `pubspec.lock` が書き換わり（SDK 同梱の `meta` / `test` / `test_api` / `test_core`）、端末間で ping-pong する（[#836](https://github.com/pooza/capsicum/issues/836)）。

- CI 側の正本は `.github/workflows/` の `flutter-version`（analyze.yml / linux-release.yml / windows-release.yml の 3 箇所。**必ず 3 つ同時に更新する**）
- 開発機は Flutter SDK の clone で `git checkout <version>` して揃える
- 版を上げるときは CI 3 ファイル + `pubspec.lock` を同一コミットで更新し、全端末を追従させる

確認手順（セッション開始時に毎回回す）は [sync-procedure.md](sync-procedure.md) のステップ 2 にある。

### 基準版に追従する（各端末で普段やる方）

```sh
cd <Flutter SDK の clone>     # 例: /opt/flutter
git fetch --tags origin
git checkout <基準版>          # 例: 3.47.9
flutter --version              # ここで bootstrap が走る

cd <capsicum>
dart run melos bootstrap
```

罠:

- **揃える前に出た `pubspec.lock` の差分はコミットしない。** 版が合っていない状態で `pub get` した結果であり、コミットすると [#836](https://github.com/pooza/capsicum/issues/836) の ping-pong が再発する
- SDK が git clone でない配置（snap / scoop / パッケージマネージャ経由）だと `git checkout` で版を動かせない。その場合は **clone 方式に置き換える**。バージョンを宣言的に固定できることが、この運用の前提
- `flutter --version` を一度通すまで SDK の bootstrap が走らないため、`dart` コマンドの版も古いままになる

### 基準版を上げる（年に数回・1 端末で代表して）

0. ⚠ **先に [#1280](https://github.com/pooza/capsicum/issues/1280) を見る。**Android の Gradle 8.14 / AGP 8.11.1 は、Flutter 3.47.7 がエラーにする下限とちょうど同じ版。新しい Flutter が下限を上げていると Android のビルドが止まる。Gradle 9 へ上げられないのは super_drag_and_drop の cargokit が `Project.exec()` を使っているためで、上流の安定版を待っている（2026-10-15 pooza）
1. SDK を新版に切り替える（上と同じ手順）
2. **CI 3 ファイルの `flutter-version` と `pubspec.lock` を同一コミットで更新する**（`analyze.yml` / `linux-release.yml` / `windows-release.yml`。1 つでも漏らすと CI 内で版が割れる）
3. `flutter analyze` / 全パッケージのテスト / 各 OS のビルドを通す
4. deprecation の移行を同じコミットに含める
5. 他の端末は「基準版に追従する」で追いつく

実例は #836（3.41.9 → 3.44.6）のコミット 2 本と、#1200（3.44.6 → 3.47.7）がそのまま雛形になる。**iOS / macOS のビルド構成に影響する変更（3.44 の SwiftPM 移行など）を含む場合は、製品版昇格前に内部ベータで検証すること。**

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
| 2 | `Binary ... does not contain architectures "arm64 x86_64"` | **Flutter ツール（上流バグ）** | 当時は `/opt/flutter` へローカル patch。**3.47.7 へ上げて解消**（下記） |
| 3 | `The macOS deployment target ... is set to 11.5, but the range of supported deployment target versions is 12.0 to 27.0.x`（**`Runner` 本体・ShareExtension・NSE**） | **アプリ本体** | **最低 macOS を 12.0 へ引き上げ**（製品判断・pooza 承認） |

⚠ **1 と 3 は同じ形だが深刻度が違う。**1 は依存を宣言済みの値に揃えるだけだが、**3 はサポート対象 OS を切る話**なので製品判断が要る。

⚠ **`Podfile` の `platform` は podspec が明示した値を上書きしない。**Flutter 標準の `flutter_additional_ios_build_settings` は **12.0 未満しか底上げしない**ので、13.0 を宣言しているもの（`flutter_web_auth_2`）は素通りする。

### `/opt/flutter` のローカル patch は外した（2026-10-12・#1200）

Xcode 27 の `lipo` は `-verify_arch` に複数アーキテクチャを渡せず、Flutter 3.44 系は 1 回でまとめて渡していたので、バイナリに両方揃っていても失敗した（flutter/flutter#188461）。2026-09-17 から `/opt/flutter` の `packages/flutter_tools/lib/src/build_system/targets/darwin.dart` にローカル patch を当ててしのいでいた。

✅ **上流の修正は 3.47.0 以降に入っている**（3.44 系には最後まで入らなかった）。基準版を **3.47.7** へ上げ、patch を外した。patch 無しで `flutter build macos --release` + `xcodebuild archive` と `flutter build ipa --release` が通ることを確かめてある（Xcode 27.0）。

⚠ **別の Mac で 3.44 系のまま Xcode 27 を使うと、同じ症状が出る。**手掛かりは `does not contain architectures "arm64 x86_64"` という**実態と逆のエラー文**（`lipo -info` は両方あると出す）。直し方は patch ではなく、[基準版に追従する](#基準版に追従する各端末で普段やる方)こと。

⚠ **基準版へ追従する前に、`git -C <SDK> status` で手元の変更を確かめる。**patch が残った端末では `git checkout <基準版>` が止まるので、先に `git checkout -- packages/flutter_tools/lib/src/build_system/targets/darwin.dart` で捨てる。

## Android Studio / SDK の版も pin していない（#1315）

Xcode と違って勝手には動かない。Android Studio 本体は更新を通知するだけで、入れるのは手で入れたときだけ。SDK のパッケージ（`emulator` / `platform-tools` / `build-tools` / `platforms` / `cmdline-tools`）も、SDK Manager か `sdkmanager` で上げたときだけ動く。⚠ **ただし Mac は Tsunagal と共用**で、向こうの作業で上がることがある（#1314・#1316）。**上げた側が、上げたものと版を Issue に残す**（#1314 の形）。

⚠⚠ **`JAVA_HOME` は Android Studio 同梱の JDK（`Android Studio.app/Contents/jbr`）を指している。**本体を上げると JDK も変わり、Gradle のビルドに効く。SDK のパッケージを上げるより影響が大きい。上げる前後で `"$JAVA_HOME/bin/java" -version` を控える。

### 上げる時期と、上げた後のスモーク

⚠ **リリースの直後に上げる**（Xcode と同じ理由: 壊れても次のリリースまでが復旧の余裕になる）。上げたらその場で次を通す:

```sh
flutter doctor -v                       # Android toolchain の節に ✗ が無い
adb devices                             # 実機が出る
"$ANDROID_SDK_ROOT/emulator/emulator" -avd <AVD>   # エミュレータが起動する
cd packages/capsicum
source ~/.config/capsicum/secrets.env
flutter build appbundle --release --dart-define=SENTRY_DSN=$SENTRY_DSN --dart-define=SENTRY_ENV=production --dart-define=RELAY_SECRET=$RELAY_SECRET
ls -la build/app/outputs/bundle/release/app-release.aab   # 終了コードでなく成果物で判定する
```

⚠ リリース本番のビルドは、16KB ページ整列のフラグと gradle daemon の止め方が加わる（[store-release の build-upload](../.claude/skills/store-release/build-upload.md)）。スモークはビルドが通るかだけを見るので、上の形でよい。

⚠ 2026-10-25 の時点で、本体（2025.2）と `cmdline-tools`（19.0・23.0 が出ている）は上げていない。次のリリースの直後に上げる候補。

## 同じ Mac に同居する Tsunagal との共有物（#1316）

メインの Mac には、Tsunagal（同じく Flutter）の開発環境が同居している。Claude Code のセッションも別々に動く。⚠⚠ **この節が正本**で、Tsunagal 側の docs はここへリンクするだけにする（2026-10-27 pooza 判断・二重に書かない）。

| もの | 共有の形 | 決まり |
| --- | --- | --- |
| Flutter 本体 | `/opt/flutter` の 1 つ。capsicum の基準は CI の pin（`analyze.yml`）、Tsunagal の基準は `.fvmrc` | **今は分けない**（どちらも同じ版）。片方だけ上げたい時期が来たら、そのときに分ける（Tsunagal は fvm を前提にしている） |
| Android SDK | 1 か所を両方が使う | 下の「上げるとき」 |
| JDK | 両方の `JAVA_HOME` が Android Studio 同梱の JDK | 本体を上げると両方の Gradle が変わる（上の節） |
| エミュレータ | 共用だった AVD が 1 台と、Tsunagal 専用の AVD（2026-10-19 に作った） | **共用だった AVD は capsicum 専用と見なす**。Tsunagal は自分の AVD を使う |
| Gradle のキャッシュ | `~/.gradle` | 版ごとに分かれるので、ぶつかりにくい |

### 上げるとき（#1314 の形）

- **上げるかどうかは pooza が決める。**どちらのセッションも、共有物を自分の判断で上げない
- **上げた側のセッションが、もう片方のリポジトリに記録の Issue を立てる。**上げたものと前後の版、上げた後に通したスモークを書く（#1314 が実例）。capsicum 側で上げたときは Tsunagal のリポジトリへ、Tsunagal 側で上げたときは capsicum へ
- 受け取った側は、自分の手順（capsicum なら上の「上げる時期と、上げた後のスモーク」）を通して閉じる

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

### この GUI 操作は 2 つのことを同時にやっている（2026-10-03 実測）

⚠⚠ **片方だけでは効かない。**

| | 書かれる場所 |
| --- | --- |
| 1. `.storekit` を**プロジェクトに登録**する | `Runner.xcodeproj/project.pbxproj`（`PBXFileReference` + グループの `children`） |
| 2. **スキームに参照を書く** | `Runner.xcscheme` の `<StoreKitConfigurationFileReference identifier = "../Capsicum.storekit">` |

⚠ **`Capsicum.storekit` は `project.pbxproj` に登録されていない**（2026-10-03 時点）。なので**スキームだけ書いても Xcode が参照を解決できず、黙って無視される。**

### 🔴 `flutter run` では効かない

**スキームに書いても `flutter run` 経由では適用されない**（2026-10-03 実測）。あの設定は **Xcode の Run アクションが起動時に効かせる**もので、`flutter run` はビルド後に自前でインストール・起動するため通らない。⚠ **画面は出るが商品が 0 件**になり、「ストアに接続できないか、商品情報を取得できませんでした」と表示される。

⚠ `xcodebuild test`（スキームの TestAction に同じ参照を書く）も試したが**効かなかった** —— アプリをホストにした unit test では適用されない模様。**撮影は Xcode の ▶︎ で起動する前提で組むこと。**

### 画面の撮り方（操作を減らす）

⚠ **外から `xcrun simctl io … screenshot` を撃つとビルド時間とレースになる**（2026-10-03 に 2 回外した）。⚠⚠ **`xcodebuild test` はシミュレータをクローンして走る**ので、アプリのサンドボックスへ書いたファイルは**クローンごと消える**（`-parallel-testing-enabled NO -disable-concurrent-destination-testing` で本体に寄せられる）。

⚠ **到達に要るタップを減らす手がある。**`lib/src/router.dart` の `resolveRedirect` を素通しにし、`initialLocation` を `/settings/supporter` にすると、**起動直後に目的の画面が出る**（ログインも画面遷移も不要）。⚠⚠ **一時変更には目印を付け、絶対にコミットしないこと。**

### 🔴 これで購入しても「動いた」ことにはならない

| | |
| --- | --- |
| 出るもの | ✅ 商品名・価格・購入シート（**見た目は本物と同じ**） |
| 出ないもの | 🔴 **ストアの本物のレシート** |

⚠⚠ **relay の `POST /entitlements` は偽の `purchase_id` を受け取る**ので、App Store Server API の検証が通らず **`unverified` のまま**になる。**「購入 → 利用権が有効」の実測にはならない。**それはサンドボックス（本物の Apple ID のテスター）でやる。

⚠ **投げ銭 3 種もこのファイルに入れてある。**StoreKit Configuration を有効にすると**そのファイルにある商品しか返らない**ので、抜くと投げ銭の節が消えて**画面が本番と違う形で写る**。

## Claude Code の権限設定（auto モード・全端末）

⚠ **別ファイルにある → [dev-environment-claude-code.md](dev-environment-claude-code.md)「Claude Code の権限設定」。**`.claude/settings.json` と `settings.local.json` の書き分け・`autoMode` の書き方・ssh の allowlist・落とし穴（認証情報を画面へ読み出す手順は通らない、など）はそちら（2026-10-26 に移した）。⚠⚠ **新しい端末に着いたら、作業の前に読む。**

## コマンドの書き方（許可確認を出さないための約束）

⚠ **別ファイルにある → [dev-environment-claude-code.md](dev-environment-claude-code.md)「コマンドの書き方」。**要点は `jq` を使う（インタプリタに逃げない）/ ループと関数定義を書かない / `cd` しない（`git -C` か `(cd X && cmd)`）/ `gh` の書き込みに `--repo` / 絶対パスで呼ばない / 検査コマンドをパイプに繋がない。⚠ **hook の拒否メッセージとスキルがこの見出しを名指ししているので、見出しは消さない**（2026-10-26 に移した）。

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

### `secure_storage.timeout` の読み方（#1166）

- **1 プロセスにつき 1 回しか送らない。**最初に打ち切られた処理の `phase` だけが載るので、**`phase` の内訳は「どの処理が多いか」ではなく「どの処理が先に走るか」を表す**。`push_key` が先に出た起動では、アカウントの secret のぶんは上がらない。件数の比で優先度を決めないこと。
- アカウントの secret の `phase` は 2.1 から `account_secret`（2.0 までは `startup_secret`。起動時の復元だけでなく保存・削除にも使われていて、名前と実態がずれていた）。過去のぶんを引くときは旧い値で絞る。どの操作かは `secure_storage_stage` タグ（`probe` / `read` / `write` / `delete` ほか）で分かる。

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
