# 開発環境・検証端末

開発マシン・実機検証端末・Android エミュレータのセットアップに関するメモ。個人環境前提のため、他マシンに移行する際の参照用。

## 対応 OS

メインの開発ホストは **macOS**。Apple toolchain（Xcode / fastlane / 各種証明書 / `.p8` 鍵）と Android toolchain・Sentry dSYM アップロード環境がここに揃っており、リリースサイクルおよび iOS / Android / macOS 向けビルドはすべてこのマシンで行う。

v1.24（[CLAUDE.md](CLAUDE.md#デスクトップ対応) のデスクトップ対応 第3段階）以降は Linux / Windows を **補助機**として併用する。Flutter のデスクトップビルドは `flutter build linux` / `flutter build windows` ともクロスコンパイル不可で、配布パイプライン（[#423](https://github.com/pooza/capsicum/issues/423) / [#424](https://github.com/pooza/capsicum/issues/424)）と実機検証（[#425](https://github.com/pooza/capsicum/issues/425)）はそれぞれの OS でしか進められないため。補助機は OS 固有作業（Linux/Windows ビルド・配布物生成・実機検証）専用で、リリース判定・ストア公開・各種シークレット管理はメインの macOS に集約する。

## Debug ビルドと TestFlight の役割分担

Debug ビルドは「コードを動かしてみるための環境」であり、本番相当の検証は TestFlight / 内部テストトラックで行う。Debug 環境で本番と同じ機能スイートが揃わなくても、TestFlight 経由で検証できるなら気にしない方針。

具体例:

- **App Group / Keychain Access Group**: Debug ビルドは Release と同じ App Group ID (`group.jp.co.b-shock.capsicum`) と keychain-access-groups を共有しているため、Debug で動かした capsicum が ShareExtension 用 App Group コンテナへ書いたファイルを Release インスタンスが読む経路ができる ([#504](https://github.com/pooza/capsicum/issues/504))。本来は Debug 用に別 App Group ID (`group.jp.co.b-shock.capsicum.debug`) を分離すべきだが、開発機限定で同居する debug + release のクロス参照は実害が薄く、Xcode / Apple Developer Portal 側の provisioning 作業コストに見合わない。TestFlight 経由の検証で sandbox 境界の挙動は担保される
- **macOS Debug の sandbox オフ**: ad-hoc 署名 + sandbox の組み合わせで ASWebAuthenticationSession / Keychain (`flutter_secure_storage`) が `errSecMissingEntitlement` (-34018) で動かないため、Debug は `com.apple.security.app-sandbox=false` で運用している。これも sandbox 挙動の検証は TestFlight で行う前提で運用ルール化されている
- **APNs / FCM / dart-define 機密値**: 本物の値が必要なケースは Debug では検証成立しないため、TestFlight / 内部ベータ経由で検証する

判断ルール: 「Debug で再現しないからどうにかしたい」となったら、まず **TestFlight 経由で検証する経路があるか** を確認する。あるなら Debug を本番並みに引き上げるコストはかけない。

## メイン (macOS) セットアップ

- `~/.config/capsicum/` に App Store Connect API Key（`.p8`）と Google Play サービスアカウント JSON キーを配置（Fastfile から参照。具体的なファイル名・Key ID 等は非公開）
- `~/.config/capsicum/secrets.env` を Google Drive 上の実体への symlink で配置（`SENTRY_DSN` / `RELAY_SECRET` を複数 PC で共有するため。実体パスは非公開）
- Xcode → Settings → Accounts で Apple ID 追加 → Manage Certificates → Apple Distribution 証明書を作成
- `gem install fastlane`（rbenv の Ruby を使用）
- Android 署名鍵 `android/key.properties` を配置（git 管理外、手動配置）
- リポジトリルートの `.sentryclirc`（git 管理外）に dSYM アップロード用トークンを配置（`sentry_dart_plugin` が自動参照）
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
  libmpv-dev libasound2-dev libayatana-appindicator3-dev \
  libfuse2t64 patchelf
```

- `libgtk-3-dev` / `libsecret-1-dev`: Flutter desktop と flutter_secure_storage 用
- `libwebkit2gtk-4.1-dev`: `flutter_web_auth_2` が transitive で引く `desktop_webview_window` の OAuth 用 WebView (#382 で OS デフォルトブラウザ方式に切り替えれば不要になる候補)
- `libcurl4-openssl-dev`: sentry-native の HTTP 送信
- `default-jdk-headless`: `sentry_flutter` が transitive で引く `jni` のヘッダ (ビルド時のみ。実行時は使われない)
- `libmpv-dev`: `media_kit_video`（[#492](https://github.com/pooza/capsicum/issues/492) media_kit 移行 v1.30）が cmake で `PkgConfig::mpv` を要求。同梱 libmpv があってもビルド時に system 側が要る
- `libasound2-dev`: `volume_controller` が ALSA（`find_package(ALSA)`）を要求
- `libayatana-appindicator3-dev`: `tray_manager`（デスクトップ常駐トレイ [#752](https://github.com/pooza/capsicum/issues/752)）が `ayatana-appindicator3-0.1` を要求
- `libfuse2t64` / `patchelf`: AppImage 起動と linuxdeploy の依存解決

なお、上記 system 依存に加えて、フレッシュな checkout では **`melos bootstrap` + `melos run build_runner`（`fediverse_objects` の `*.g.dart` 生成）が済んでいないと `flutter build/run linux` が `_$XxxFromJson` 未定義でコンパイル失敗**する。melos は Pub Cache bin が PATH 外だと解決に失敗するため `export PATH="$PATH:$HOME/.pub-cache/bin"` を通しておく（Windows 固有節の build_runner 注記と同型）。

配布パイプライン作業時の `linuxdeploy` / `linuxdeploy-plugin-gtk.sh` / `appimagetool` は GitHub Releases から `~/.local/bin/` に直接配置（`sentry-cli` と同じ運用）。具体手順は [packaging/linux/appimage/README.md](../packaging/linux/appimage/README.md)。

### Windows 固有

- 検証端末は 2 系統: (1) **Parallels Desktop 上の Windows 11 VM（ARM、メイン macOS に同居）** — v1.25 配布パイプライン [#423](https://github.com/pooza/capsicum/issues/423) の実装・MSIX 自己署名インストール検証はこの VM 上で行う。(2) **x64 実機 Windows 11**（2026-06-12 に ARM 環境から移行して追加）— 下記のローカルソースビルド（`flutter build windows`）が通るのはこちら
- Visual Studio 2022 Build Tools（"Desktop development with C++" workload）
- MSIX packaging tool（[#423](https://github.com/pooza/capsicum/issues/423) の MSIX 生成用）
- Microsoft Partner Center アカウント（Microsoft Store 登録用）
- 内部ベータ検証経路: GitHub Actions の `Windows Release` workflow を develop で `workflow_dispatch` 起動 → artifact (`capsicum.msix` + `capsicum-signing.cer`) を Parallels VM 内でダウンロード → [packaging/windows/INSTALL.md](../packaging/windows/INSTALL.md) に従って `Import-Certificate` + `Add-AppxPackage`。タグ駆動の draft Release ([store-release-guide.md §4.6](store-release-guide.md)) と同じ MSIX が出るため、本番判定にも流用できる（リリース後のエンドユーザー手順とも完全同一）
- **ローカルソースビルドは ARM Windows（上記 VM）では通らない**ため、ARM 環境での検証は上記 CI artifact の MSIX で行う。ARM で詰まる箇所: `flutter_secure_storage_windows` / `flutter_local_notifications_windows` が ATL ヘッダ（`atlstr.h` / `atlbase.h`、VS Build Tools に「C++ ATL for v143」追加が必要）、`jni` が `jni.h`（JDK 未導入）、`sentry-native`（crashpad）が x64 ターゲットビルド中に ARM64 専用 marmasm targets を踏む。前 2 つは追加導入で解決余地があるが crashpad の ARM/x64 不整合が残るため深追いしない
- **x64 実機では `flutter build windows --release` が通る**（2026-06-12 確認。crashpad の ARM/x64 不整合は x64 ネイティブでは発生しない）。必要なツールチェーン: VS Build Tools 2022 の「C++ によるデスクトップ開発」ワークロード + **C++ ATL** + **C++ CMake tools** + **Windows 11 SDK**（`Microsoft.VisualStudio.Workload.VCTools --includeRecommended` で一括導入可。GUI が白画面で開けない場合は `setup.exe modify ... --quiet` で CLI 導入。`--wait` は modify では不可）、`jni.h` 用の **JDK**（`JAVA_HOME` 設定）、**Windows 開発者モード ON**（無効だとシンボリックリンク作成で失敗）、`melos bootstrap` + コード生成（`build_runner` が必要なのは `fediverse_objects` のみ。`melos run build_runner` は Pub Cache bin が PATH 外だと内部の `melos` 解決に失敗するため、当該パッケージで直接 `dart run build_runner build` する）
- MSIX は release build なので、debug では確認できない OS 連携系（`window_manager` の位置・サイズ復元 #559 / OAuth の OS デフォルトブラウザ起動 #382 系 / OS スキーム・ネイティブダイアログ）も artifact MSIX 経由で内部ベータ同等に先行検証できる（x64 MSIX は ARM Windows 上でエミュレーション動作する）

### 持ち込まないもの

- Apple toolchain（Xcode / fastlane / Apple Distribution 証明書 / `AuthKey_*.p8`）
- Android 署名鍵（`android/key.properties`）/ Google Play サービスアカウント JSON
- リポジトリルートの `.sentryclirc`（dSYM アップロード用、iOS/Android/macOS 専用）

リリース判定・ストア公開・iOS/Android/macOS の dSYM アップロードはすべてメインの macOS で行うため、補助機にこれらを置く必要はない。

## Sentry

- 組織アカウントの Sentry を利用（プロジェクト `capsicum`、有料プラン契約済み。ダッシュボード URL は非公開）
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

- 実機接続時は Parallels Desktop を終了させること（Parallels が USB デバイスを横取りするため）
- iOS アップデート後にデベロッパモードがリセットされることがある → 設定 → プライバシーとセキュリティ → デベロッパモード で再有効化

## Android エミュレータ環境

- `ANDROID_SDK_ROOT` / `JAVA_HOME` を設定し、`$ANDROID_SDK_ROOT/emulator/emulator -avd <AVD>` でエミュレータを起動（arm64 AVD を使用）

### エミュレータで既知の問題

- カスタムスキーム `capsicum://oauth` のリダイレクトが Android エミュレータで動作しない（OOB 方式で代用中）。[tech-notes.md](tech-notes.md) の認証フロー節も参照

（個々の検証端末・UDID・AVD 名・SDK パスといった端末固有の具体値は、public リポジトリには置かず別途管理する）
