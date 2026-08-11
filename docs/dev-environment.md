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

### その端末で拾う作業の探し方

**`Windows` / `Linux` ラベルが「その実機でないと進まない」ものの目印。** メインの macOS では踏み込めない（再現確認が起点・修正案の選択が実機の挙動次第）ものだけを付ける。着いたらまずこれを引く:

```sh
gh issue list --state open --label Windows   # Windows 機で
gh issue list --state open --label Linux     # Linux 機で
```

`desktop` ラベルとは別物であることに注意。`desktop` は 3 OS 共通のデスクトップ機能（メニューバー等）で、**macOS でも進められる**。ラベルの貼り替えは、実機で確認して「macOS でも書ける」と分かった時点で外す。

対象が無くなったら、そのマイルストーンの残りをマイルストーン一覧から拾う。

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

配布パイプライン作業時の `linuxdeploy` / `linuxdeploy-plugin-gtk.sh` / `appimagetool` は GitHub Releases から `~/.local/bin/` に直接配置（`sentry-cli` と同じ運用）。具体手順は [distribution/linux/appimage/README.md](../distribution/linux/appimage/README.md)。

### Windows 固有

- 検証端末は 2 系統: (1) **Parallels Desktop 上の Windows 11 VM（ARM、メイン macOS に同居）** — v1.25 配布パイプライン [#423](https://github.com/pooza/capsicum/issues/423) の実装・MSIX 自己署名インストール検証はこの VM 上で行う。(2) **x64 実機 Windows 11**（2026-06-12 に ARM 環境から移行して追加）— 下記のローカルソースビルド（`flutter build windows`）が通るのはこちら
- Visual Studio 2022 Build Tools（"Desktop development with C++" workload）
- MSIX packaging tool（[#423](https://github.com/pooza/capsicum/issues/423) の MSIX 生成用）
- Microsoft Partner Center アカウント（Microsoft Store 登録用）
- 内部ベータ検証経路: GitHub Actions の `Windows Release` workflow を develop で `workflow_dispatch` 起動 → artifact (`capsicum.msix` + `capsicum-signing.cer`) を Parallels VM 内で [install-internal-beta.ps1](../distribution/windows/install-internal-beta.ps1)（`gh run download` + `Import-Certificate` + `Add-AppxPackage` を管理者昇格つき 1 コマンドに畳んだもの）で導入。タグ駆動の draft Release ([store-release-guide.md §4.6](store-release-guide.md)) と同じ MSIX が出るため、本番判定にも流用できる。**自己署名 MSIX 直配はあくまで内部ベータ / 開発検証用**でエンドユーザーには案内しない（Windows の公式配布は Microsoft Store 単独・[#760](https://github.com/pooza/capsicum/issues/760)）
- **ローカルソースビルドは ARM Windows（上記 VM）では通らない**ため、ARM 環境での検証は上記 CI artifact の MSIX で行う。ARM で詰まる箇所: `flutter_secure_storage_windows` / `flutter_local_notifications_windows` が ATL ヘッダ（`atlstr.h` / `atlbase.h`、VS Build Tools に「C++ ATL for v143」追加が必要）、`jni` が `jni.h`（JDK 未導入）、`sentry-native`（crashpad）が x64 ターゲットビルド中に ARM64 専用 marmasm targets を踏む。前 2 つは追加導入で解決余地があるが crashpad の ARM/x64 不整合が残るため深追いしない
- **x64 実機では `flutter build windows --release` が通る**（2026-06-12 確認。crashpad の ARM/x64 不整合は x64 ネイティブでは発生しない）。必要なツールチェーン: VS Build Tools 2022 の「C++ によるデスクトップ開発」ワークロード + **C++ ATL** + **C++ CMake tools** + **Windows 11 SDK**（`Microsoft.VisualStudio.Workload.VCTools --includeRecommended` で一括導入可。GUI が白画面で開けない場合は `setup.exe modify ... --quiet` で CLI 導入。`--wait` は modify では不可）、`jni.h` 用の **JDK**（`JAVA_HOME` 設定）、**Windows 開発者モード ON**（無効だとシンボリックリンク作成で失敗）、`melos bootstrap` + コード生成（`build_runner` が必要なのは `fediverse_objects` のみ。`melos run build_runner` は Pub Cache bin が PATH 外だと内部の `melos` 解決に失敗するため、当該パッケージで直接 `dart run build_runner build` する）
- MSIX は release build なので、debug では確認できない OS 連携系（`window_manager` の位置・サイズ復元 #559 / OAuth の OS デフォルトブラウザ起動 #382 系 / OS スキーム・ネイティブダイアログ）も artifact MSIX 経由で内部ベータ同等に先行検証できる（x64 MSIX は ARM Windows 上でエミュレーション動作する）
- **Windows runner の純ロジック C++ テストは Mac の clang でも走る**。`windows/runner/notification_tag_test.cpp` / `notification_dedup_test.cpp` は Windows 固有 API に依存しないので、`cd packages/capsicum/windows/runner && clang++ -std=c++17 -o /tmp/t notification_tag_test.cpp notification_tag.cpp && /tmp/t`（dedup も同様）で macOS から検証できる（2026-08-10 実行・全通過）。テストのヘッダは `cl`（VS Developer 環境）しか案内していないため Windows CI 待ちにしがちだが、ロジックだけの変更ならここで即確認できる

#### トラブルシュート: RustDesk 経由で capsicum が真っ白

Linux 機から RustDesk で Windows 実機を操作していると、capsicum のウィンドウが真っ白になることがある。**RustDesk（画面キャプチャ）側の現象で capsicum のバグではない**。Flutter の Windows 版は ANGLE（OpenGL ES → Direct3D 11）+ DirectComposition で画面を出しており、キャプチャ側がその面を拾えないとクリアカラー（白）だけが取り込まれる。描画自体は GPU 上で正しく走っていて、取り込みだけが空になっている。「実機で操作すると直る」のはこのため。

**capsicum 側の対応は不要**（環境側の再発防止メモとしてここに置く。Issue は起こしていない）。**2026-08-10 に原因を特定**（下記）。

##### 原因（2026-08-10 確定）

**蓋のセンサーが「閉じている」と判定し、Windows が内蔵パネルを落としていた。** この端末は蓋を閉じない運用だが、**蓋の間に CD の空ケース（数ミリ）を挟んで開けていた**ため、磁気式の蓋センサーには「閉じている」と見えていた。`LIDACTION` は AC / DC とも **0 = 何もしない**なのでスリープはせず、**パネルだけが消える**。結果、アクティブな出力がゼロになりキャプチャが壊れる。

**裏取り**（同日実測）:

| 蓋の状態 | `Get-CimInstance -Namespace root\wmi WmiMonitorBasicDisplayParams` |
| --- | --- |
| CD ケースで数ミリ開放（白抜け発生中） | **0 件**（アクティブなモニターなし） |
| 大きく開けた直後 | `DISPLAY\AUO562D\...` **Active=True** |

このとき `\\.\DISPLAY1 1920x1080` はどちらの状態でも残っており、GPU も 1920x1080 と報告していた。**描画先はあるのに実在するモニターがゼロ**という状態がキャプチャを壊す。**再発時はまずこの WMI クエリを撃つ**のが最短。0 件なら出力側の問題で確定し、capsicum も RustDesk の設定も見なくてよい。

**対策**: **HDMI ダミープラグ**を挿すのが本命。Windows が外部モニターを認識し続けるため、**蓋を完全に閉じてよくなる**（`LIDACTION = 何もしない`が設定済みなのでスリープしない）。CD ケースも不要になる。ソフト的な仕掛けが要らず保守もゼロ。代替は仮想ディスプレイドライバ（ハード不要・リモート導入可）と RDP への移行（物理ディスプレイに非依存だが実機画面の共有ができず描画経路も変わる）。

##### なぜ Flutter の窓だけが白くなるのか

**白くなるのは Flutter 製のウィンドウだけ**で、エクスプローラー等の従来型ウィンドウやデスクトップは正常に映る。**RustDesk 自身の UI も Flutter 製**（1.2 以降）のため、capsicum と RustDesk の窓が揃って白くなる。共通点は「RustDesk かどうか」ではなく「Flutter かどうか」。

これと整合する機序は、**RustDesk が DXGI Desktop Duplication ではなく GDI（BitBlt）キャプチャで取り込んでいる**というもの。GDI キャプチャは、ディスプレイ出力が生きている間は DWM が実フロントバッファへ合成するので DirectComposition の中身も一緒に取れるが、**出力が落ちると GPU 合成分の更新が止まり、GDI で自前描画する従来型ウィンドウだけが映り続けて Flutter のウィンドウが白く抜ける**。「実機で操作すると直る」も説明できる。

**2026-08-10、その GDI 経路が「フォールバック」ではなく設定だったことが判明した。** `enable-directx-capture = 'N'` が書かれており、**DXGI Desktop Duplication が明示的に無効化されていた**（既定値なら書かれないキー）。

**この `'N'` を書いたのは RustDesk 自身**と見てよい。**設定 UI にこの項目は存在しない**ので人手では設定できず、DXGI キャプチャの失敗時に自動で無効化されたと考えるのが自然。つまり **`'N'` はこの端末にとって正しい落としどころだった**。同日いったん `'Y'` へ変えて検証したが、**`'N'` に戻して確定**（下記のとおり `'Y'` だと出力が無い間は接続そのものが張れず、`'N'` なら白いだけで操作は続けられるため。**`'N'` が安全側**）。なお `enable-hwcodec = 'N'` のほうは UI に項目があるので人手の可能性がある。

**ただし、これは本丸ではなかった。** ディスプレイが落ちている間、`'N'`（GDI）では Flutter の窓が白抜け、`'Y'`（DXGI）では**接続そのものが張れない**。**どちらの経路でも壊れる**なら、共通の原因はキャプチャ方式ではなく「アクティブな出力が無いこと」自体である。

**Modern Standby のスロットリングを示す実測**: ディスプレイを強制オフした状態で `Start-Sleep -Seconds 25` を回すと、実測 **66 秒 / 70 秒**（2 回とも）かかった。ディスプレイオフを契機に低電力アイドル（DRIPS）へ入り、プロセスが絞られている。RustDesk のサーバープロセスも同様に絞られていれば、接続を受けられないのは当然で、**キャプチャ設定をどういじっても届かない**。

##### RustDesk の設定を変えるときの注意（2026-08-10 に踏んだ）

- **正本はサービス（LocalService）側の config**: `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml`。`%APPDATA%\RustDesk\config\RustDesk2.toml` はここから同期されて**上書きされる**（ログの `config2 synced`）。ユーザー側だけ書き換えると 1 分ほどで消える。両方書き換え、サービスを再起動する（要管理者）。
- 1.4.7+65 / 1.4.9+67 とも**設定 UI に DirectX キャプチャの項目が見当たらない**ため、ファイル直編集が要る。
- **RustDesk は自動アップデートする**（2026-08-10 のセッション中に 1.4.7+65 → 1.4.9+67 へ勝手に上がり、MSI インストールで接続が切れた）。切断の原因を切り分けるときは、まず `%APPDATA%\RustDesk\log\RustDesk_rCURRENT.log` で更新が走っていないかを見る。
- **観測の成否はログで裏取りできる**: `%APPDATA%\RustDesk\log\cm\RustDesk_rCURRENT.log` に接続の open / close が出る。テスト時間帯に接続が無ければその検証は空振り。

| 観測 | この仮説での説明 |
| --- | --- |
| Flutter のウィンドウだけ白い | DirectComposition が GDI キャプチャに映らない |
| 他のアプリ・デスクトップは正常 | 従来型ウィンドウは GDI で取れる |
| 実機で操作すると直る | ディスプレイ出力が復帰し Desktop Duplication に戻る |
| ディスプレイ電源オフを止めても再発 | 出力が落ちる理由は電源設定以外にもある |
| RustDesk 自身の窓も白い | RustDesk の UI も Flutter |

##### 潰した原因・取り下げた仮説

- **ロック経由（`VIDEOCONLOCK`）— 2026-08-10 に否定**。同日 AC=0 を適用したが、その後に再現した。常駐ログ（`display-watch`）で**白くなっている最中も `lock` は全行 `no`**＝ロック画面は出ていない。設定自体は害がないので 0 のまま残す。
- **Modern Standby のスロットリング — 2026-08-10 に否定**。同じ時間帯の `drift` が全行 30 秒ちょうどで、低電力アイドルに落ちていない。ディスプレイオフ中に `Start-Sleep` が伸びる現象は**強制オフしたときには起きた**が、実際の再現時には起きていない＝別経路。
- **待機タイマー（`VIDEOIDLE` / `STANDBYIDLE`）— 対象外**。AC 側は両方 0 で、そもそも発火しない。

- **AC 時のディスプレイ電源オフ（2026-07-23 に対策済み・これだけでは直らない）**: この端末は AC 電源時に 60 分でディスプレイの電源が切れる設定だった。`powercfg /change monitor-timeout-ac 0` を適用済みで、2026-08-06 に AC=0x0 のまま生きていることを実測確認した。**それでも再発する**ため、当時「特定した主因」と書いたのは言い過ぎで、実際には出力面が消える経路の 1 つを潰しただけだった。逆戻しは `60` を入れる。
- **バッテリー駆動時のディスプレイ電源オフ / スリープ（DC=180 秒のまま）**: `monitor-timeout-ac` は AC 側しか変えないため DC には残っているが、**この端末はバッテリー駆動で使わない**運用なので対象外。
- **スクリーンセーバー**: `ScreenSaveActive=1` だがセーバー本体もタイムアウトも未設定で、実質動いていない。
- **MPO（マルチプレーン オーバーレイ）**: `HKLM\SOFTWARE\Microsoft\Windows\Dwm` の `OverlayTestMode=5` で無効化する案を検討したが、**複数の Flutter ウィンドウが揃って白くなる説明が苦しい**ため取り下げ（オーバーレイ面への昇格は本数が限られる）。現在 `OverlayTestMode` は未設定＝MPO 有効のまま。GPU は Intel UHD Graphics 620、ドライバは 2024-08-13 版。
- **RustDesk の「ハードウェアコーデック」トグル**: エンコード＝送信側の設定であり、キャプチャ取り込み経路とは別。切り分けから外してよい。

##### 切り分けの手順

1. **白いのは Flutter 製ウィンドウだけか**を最初に見る。デスクトップ全体が白いなら上記の見立ては外れで、キャプチャ経路そのものの停止を疑う。
2. **判別テスト**（キャプチャ由来か app 由来か）: 白い時にウィンドウを**リサイズ or 最小化→復元**して中身が出れば = キャプチャ由来（app バグではない）。その時刻の **Sentry イベントの有無**でも切り分けられる（あれば app 由来を疑う）。
3. **常駐ログを読む**: `C:\Users\user\display-watch\watch.log`（2026-08-10 に仕掛けた。30 秒ごとに 1 行・最長 48 時間で自動終了）。列の意味は `drift`（前回からの実経過秒。30 のはずが大きく飛んでいたら低電力アイドルでスロットリングされた証拠。`<-- THROTTLED` が付く）/ `lock`（`LogonUI.exe` の有無。`YES` が出れば `VIDEOCONLOCK` 経路が実在すると裏付けられる）/ `idle`（最終入力からの秒数）/ `power`。**白くなった時刻と突き合わせる**のが使い方。止めるときは該当 PowerShell プロセスを終了するだけ。再開はスクリプトを再実行する（スクリプト本体は Claude のスクラッチパッドにあるので、必要なら作り直す）。

**再現を待つときの注意**: この端末は AC 接続かつ `VIDEOIDLE` / `STANDBYIDLE` とも AC=0 なので、**放置しても Windows の待機タイマーでは消えない**。手元で再現させたいなら `SC_MONITORPOWER` で強制的に消す（`WM_SYSCOMMAND` を `HWND_BROADCAST` へ。管理者権限不要）。ただし**復帰は入力で起きる**ため、RustDesk 越しにマウスを動かすとその時点でテストが終わる。オフ中は触らず、自動復帰させる作りにすること。**接続が張られていない時間帯にテストしても空振り**になるので、`%APPDATA%\RustDesk\log\cm\RustDesk_rCURRENT.log` で接続の有無を必ず確認する（2026-08-10 に 2 回空振りした）。

##### 対策候補

**方針: 出力を絶やさない側で解く。** キャプチャ方式の切り替えでは両経路とも壊れることが分かったので、対策は「常にアクティブな出力を持たせる」「ディスプレイを落とさせない」に寄せる。

1. **仮想ディスプレイドライバ** — 物理パネルの電源状態と無関係に、常時アクティブな出力を 1 枚持たせる。**リモートから導入できる**ので、実機に触れないこの端末では本命。ダミープラグと違い物理アクセスが要らない。
2. **HDMI ダミープラグ** — 同じ効果を物理で得る。確実だが**物理アクセスが要る**。
3. **ディスプレイが落ちる側を塞ぐ**: `VIDEOIDLE` は AC=0 済みだが、**GUI に出ない `VIDEOCONLOCK`（ロック中のディスプレイ電源オフ）が未設定＝既定 60 秒**で残っていた。**2026-08-10 に AC=0 を適用済み**（`powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO 8EC4B3A5-6868-48c2-BE75-4F3044BE88A7 0` → `powercfg /S SCHEME_CURRENT`）。ロックが実際に掛かっている証拠は未取得だが、犯人を特定せずに経路をまとめて塞げるため先に打った。**効果は観察待ち**。
4. **Modern Standby を切る**（`HKLM\SYSTEM\CurrentControlSet\Control\Power` の `PlatformAoAcOverride=0`・要再起動）— スロットリングごと無効化できるが影響範囲が大きい。1〜3 で足りなければ。
5. その場復帰: リサイズ / RustDesk 再接続 / ホスト再起動。
6. **GPU ドライバの更新**（現在 2024-08-13 版）。

##### この端末の電源設定の実測値（2026-08-10）

Latitude 5300（ノート・Modern Standby 機）。再現待ちを空振りさせないための前提。

- `VIDEOIDLE`（ディスプレイ電源オフ）: **AC = 0**（無効）/ DC = 180 秒
- `STANDBYIDLE`（スリープ）: **AC = 0**（無効）/ DC = 180 秒
- 電源: **AC 接続中**。したがって**放置してもディスプレイは自動では切れない**（再現を待つのは無駄）
- 直近 5 日間、**Kernel-Power のスリープ/復帰イベントがゼロ** = システムは寝ておらず、落ちているのはディスプレイだけ
- Dell Optimizer / ExpressSign-in（近接センサーの Walk Away Lock）は**未導入**（Dell Touchpad のみ）。この線は消えた
- `LIDACTION`（蓋を閉じたとき）: AC / DC とも **0 = 何もしない**。ただし**この端末は蓋を閉じない運用**なので、蓋起因の線は最初から無い
- `VIDEOCONLOCK`（ロック中のディスプレイ電源オフ）: 既定 60 秒のままだったので **2026-08-10 に AC=0 を適用**。`VIDEOIDLE` とは別タイマーで、`VIDEOIDLE = 0` はロック画面に適用されない。「放置していると消えるのに、スリープ設定は 0」という食い違いはこれで説明が付く
- **`VIDEOCONLOCK` は電源オプションの UI に存在しない**。`Attributes` を 1（隠す）→ 0 にしても、このビルドの詳細設定ダイアログには現れなかった（`control powercfg.cpl,,3` で確認）。**`powercfg` でしか触れない設定**として扱う
- `UNATTENDSLEEP` は未設定で既定のまま

##### capsicum 側から寄せられる範囲（2026-08-10 実測）

長期化した場合に capsicum 側の緩和で凌げないかを、手元の Flutter 3.44.6（engine `d3a3293399`）のエンジン成果物を直接読んで確認した。**結論: debug / profile は今日から追加コードなしで試せる。release / MSIX は capsicum からは手が出ない。**

| ビルド | ソフトウェアレンダリングへの切り替え | 根拠 |
| --- | --- | --- |
| debug / profile | **可能・コード変更不要** | 環境変数 `FLUTTER_ENGINE_SWITCHES` / `FLUTTER_ENGINE_SWITCH_n` をエンジンが読む（`bin/cache/artifacts/engine/windows-x64/flutter_windows.dll` に当該文字列あり） |
| release | **不可** | 同じ文字列が `windows-x64-release/flutter_windows.dll` に**無い**（エンジンの env スイッチ読み取りが `FLUTTER_RELEASE` で落とされている） |

debug で試すときの起動前設定（PowerShell）:

```powershell
$env:FLUTTER_ENGINE_SWITCHES = "1"
$env:FLUTTER_ENGINE_SWITCH_1 = "enable-software-rendering"
```

release で不可な理由は環境変数だけでなく **API 経路も塞がっている**こと。公開 embedder API の `FlutterDesktopEngineProperties`（[flutter_windows.h](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/windows/public/flutter_windows.h)）が持つのは assets / icu / aot パス・Dart entrypoint と argv・`gpu_preference`・`ui_thread_policy`・`accessibility_mode` だけで、**エンジンスイッチを渡すフィールドが無い**。runner の `set_dart_entrypoint_arguments`（[main.cpp](../packages/capsicum/windows/runner/main.cpp)）が渡すのは Dart の `main(List<String>)` 引数でエンジンには届かない。ソフトウェアコンポジタのコード自体は release DLL にも入っている（`SetDIBitsToDevice` / `CreateDIBSection` あり）が、**点火する手段が無い**。エンジンにパッチを当てる話になるので採らない。

付随して分かったこと:

- **DirectComposition を使っているのは裏取り済み**（両 DLL に `DCompositionCreateDevice`）。上記の見立ての前提はここは合っている。
- ソフトウェア経路は GDI へ blit する（`SetDIBitsToDevice`）ので、**GDI キャプチャなら映るはず**というのが期待できる理屈。ただし**実際に白画面が直るかは未検証**で、そこが最大の未知数。
- release DLL に `ANGLE_DEFAULT_PLATFORM` が残っているが、バックエンドを差し替えても提示は DirectComposition のままなので本筋ではない。
- エンジンに `Impeller backend does not support software rendering` の文字列がある。ソフトウェアレンダリングを試すときは Impeller が有効なら同時に落とす必要がある。

**効果の範囲**: この緩和が効くのは debug / profile 起動時のみで、**OS 連携系の検証で使う release MSIX 経路（[Windows ローカル検証](#windows-固有)）は救えない**。ただし**リモートで動かすのは debug 版が多い**（2026-08-10 の pooza 判断）ため、debug 限定でも日常の支障はかなり削れる見込み。release MSIX での検証を取り戻すには、別途、環境側（仮想ディスプレイドライバ / HDMI ダミープラグ・GPU ドライバ更新・RustDesk のキャプチャ方式）の対策が要る。

ストア版は物理 GPU ＋ アクティブ画面で描画するため**この現象は非該当**（実ユーザーが真っ白になる原因は別で、その場合は Sentry に痕跡が出る）。**製品版の描画経路は変えない。**

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
