# 補助機（Linux / Windows）セットアップ

v1.24 以降のデスクトップ向け作業（[#423](https://github.com/pooza/capsicum/issues/423) / [#424](https://github.com/pooza/capsicum/issues/424) / [#425](https://github.com/pooza/capsicum/issues/425)）専用。Apple / Google Play 関連のシークレットや署名鍵は持ち込まない。

⚠ **開発のメインは macOS。**Flutter SDK の版・Xcode・`flutter run` の手順・**コマンドの書き方**・Claude Code の権限設定は [dev-environment.md](dev-environment.md) が正本で、この 2 機でも同じルールが効く。ここには**その 2 機でしか要らないこと**だけ置く。

## その端末で拾う作業の探し方

**`Windows` / `Linux` ラベルが「その実機でないと進まない」ものの目印。** メインの macOS では踏み込めない（再現確認が起点・修正案の選択が実機の挙動次第）ものだけを付ける。着いたらまずこれを引く:

```sh
gh issue list --state open --label Windows   # Windows 機で
gh issue list --state open --label Linux     # Linux 機で
```

`desktop` ラベルとは別物であることに注意。`desktop` は 3 OS 共通のデスクトップ機能（メニューバー等）で、**macOS でも進められる**。ラベルの貼り替えは、実機で確認して「macOS でも書ける」と分かった時点で外す。

対象が無くなったら、そのマイルストーンの残りをマイルストーン一覧から拾う。

## 共通

- リポジトリは `~/repos/capsicum` にクローン（全端末共通の配置ルール）
- Flutter SDK（stable channel に固定）、Melos（`dart pub global activate melos`）、`gh` CLI
- `sentry-cli` を GitHub Releases から `~/.local/bin/sentry-cli`（Windows は `%USERPROFILE%\.local\bin\sentry-cli.exe`）に直接配置（MacPorts / Homebrew / scoop 等のパッケージマネージャ不使用）
- `~/.sentryclirc` に Issue 読み取り用トークンを配置（メインと同じ）
- Google Drive クライアント（Drive for desktop 等）をインストールし、`~/.config/capsicum/secrets.env` を Google Drive 上の実体への symlink で配置
- Claude Code の memory ディレクトリ（`~/.claude/projects/<project-key>/memory/`）も Google Drive 上の実体（プロジェクトのフォルダ配下の `memory/`）への symlink で共有する。⚠ **リンク先のフォルダ名は `memory`。**`claude-memory` という名前を指してリンク切れになった事故が 2 端末で起きている（張ったあと `ls` で中身が見えることを確かめる。実パスは端末固有なのでここには書かない）。`<project-key>` は Claude Code 起動時に作業ディレクトリから自動生成されるため、起動後に確認してから symlink を張る

## Linux 固有

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

### `dart analyze` が `Too many open files` で結果を返さない（inotify の上限）

`dart analyze` が **`OS Error: Too many open files, errno = 24`** → `Internal error: Failed to handle request: analysis.setAnalysisRoots` で落ち、**結果を 1 行も返さない**ことがある（2026-09-08 に Debian 13 のデスクトップ機で実測）。

⚠ **fd の上限ではない**（`ulimit -n` は十分ある）。**枯れているのは inotify の instance 数**（`/proc/sys/fs/inotify/max_user_instances`・既定 128）。⚠ **リークではなく、デスクトップ環境がログイン時点で上限近くまで使う**ので、再起動しても直らない。

```sh
echo 'fs.inotify.max_user_instances=512' | sudo tee /etc/sysctl.d/99-inotify.conf
sudo sysctl --system                               # ⚠ ファイルに書くだけでは起動時まで効かない
cat /proc/sys/fs/inotify/max_user_instances        # 実効値で確かめる
ls -l /etc/sysctl.d/99-inotify.conf                # サイズが 0 でないこと
```

⚠ **書けたことを信用せず実効値で確かめる。**書いた直後に不正終了すると、再起動後にファイルが 0 バイトになっていることがある（ext4 の遅延確保）。`systemd-sysctl` は success を記録するので「service は成功なのに値が変わらない」形になる。

- sudo が使えないときは **`flutter analyze --no-pub`** が上限に当たっても完走する（info も報告する）。ただし watcher のエラーで exit code は非 0 になるので、判定は出力（`No issues found!`）で行う
- ⚠ `fs.inotify` は Linux 固有。macOS で打つと `sysctl: unknown oid` になる

## Windows 固有

- 検証端末は 2 系統: (1) **Parallels Desktop 上の Windows 11 VM（ARM、メイン macOS に同居）** — v1.25 配布パイプライン [#423](https://github.com/pooza/capsicum/issues/423) の実装・MSIX 自己署名インストール検証はこの VM 上で行う。(2) **x64 実機 Windows 11**（2026-06-12 に ARM 環境から移行して追加）— 下記のローカルソースビルド（`flutter build windows`）が通るのはこちら
- Visual Studio 2022 Build Tools（"Desktop development with C++" workload）
- MSIX packaging tool（[#423](https://github.com/pooza/capsicum/issues/423) の MSIX 生成用）
- Microsoft Partner Center アカウント（Microsoft Store 登録用）
- 内部ベータ検証経路: GitHub Actions の `Windows Release` workflow を develop で `workflow_dispatch` 起動 → artifact (`capsicum.msix` + `capsicum-signing.cer`) を Parallels VM 内で [install-internal-beta.ps1](../distribution/windows/install-internal-beta.ps1)（`gh run download` + `Import-Certificate` + `Add-AppxPackage` を管理者昇格つき 1 コマンドに畳んだもの）で導入。タグ駆動の draft Release ([store-release スキル §4.6](../.claude/skills/store-release/windows.md)) と同じ MSIX が出るため、本番判定にも流用できる。**自己署名 MSIX 直配はあくまで内部ベータ / 開発検証用**でエンドユーザーには案内しない（Windows の公式配布は Microsoft Store 単独・[#760](https://github.com/pooza/capsicum/issues/760)）
- **ローカルソースビルドは ARM Windows（上記 VM）では通らない**ため、ARM 環境での検証は上記 CI artifact の MSIX で行う。ARM で詰まる箇所: `flutter_secure_storage_windows` / `flutter_local_notifications_windows` が ATL ヘッダ（`atlstr.h` / `atlbase.h`、VS Build Tools に「C++ ATL for v143」追加が必要）、`jni` が `jni.h`（JDK 未導入）、`sentry-native`（crashpad）が x64 ターゲットビルド中に ARM64 専用 marmasm targets を踏む。前 2 つは追加導入で解決余地があるが crashpad の ARM/x64 不整合が残るため深追いしない
- **x64 実機では `flutter build windows --release` が通る**（2026-06-12 確認。crashpad の ARM/x64 不整合は x64 ネイティブでは発生しない）。必要なツールチェーン: VS Build Tools 2022 の「C++ によるデスクトップ開発」ワークロード + **C++ ATL** + **C++ CMake tools** + **Windows 11 SDK**（`Microsoft.VisualStudio.Workload.VCTools --includeRecommended` で一括導入可。GUI が白画面で開けない場合は `setup.exe modify ... --quiet` で CLI 導入。`--wait` は modify では不可）、`jni.h` 用の **JDK**（`JAVA_HOME` 設定）、**Windows 開発者モード ON**（無効だとシンボリックリンク作成で失敗）、`melos bootstrap` + コード生成（`build_runner` が必要なのは `fediverse_objects` のみ。`melos run build_runner` は Pub Cache bin が PATH 外だと内部の `melos` 解決に失敗するため、当該パッケージで直接 `dart run build_runner build` する）
- MSIX は release build なので、debug では確認できない OS 連携系（`window_manager` の位置・サイズ復元 #559 / OAuth の OS デフォルトブラウザ起動 #382 系 / OS スキーム・ネイティブダイアログ）も artifact MSIX 経由で内部ベータ同等に先行検証できる（x64 MSIX は ARM Windows 上でエミュレーション動作する）
- ⚠ **MSIX を入れる前に、既存インストールと発行元が一致するかを必ず確認する**（2026-08-16 #978 の検証で確立）。一致すれば `Add-AppxPackage` は**その場アップグレード**になり `LocalState`（push 鍵・観測スロット）もアカウント設定も残るが、**一致しないと Windows が上書きを拒否し、アンインストール（＝ログイン状態と設定の消失）が必要になる**。CI は Repository Secrets の PFX が未投入だと ephemeral cert にフォールバックするため、発行元は黙って変わりうる。

  ```powershell
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $z = [System.IO.Compression.ZipFile]::OpenRead($msix)
  $e = $z.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' }
  $sr = New-Object System.IO.StreamReader($e.Open())
  $xml = [xml]$sr.ReadToEnd(); $sr.Close(); $z.Dispose()
  $xml.Package.Identity.Publisher -eq (Get-AppxPackage -Name '9AFBB08E.capsicum').Publisher
  ```

- **native クラッシュ（minidump）のトリアージは `.sentry-native` を直接見る**（2026-08-16 [#773](https://github.com/pooza/capsicum/issues/773) で確立）。置き場は **MSIX のパッケージコンテナではなく実体の `%APPDATA%\net.shrieker\capsicum\.sentry-native\`** — capsicum は FullTrust で動くため `getApplicationSupportDirectory()` が `LocalCache` 側に落ちない（`LocalState` の push 系ファイルとは別階層なので探し間違えやすい）。見るもの:
  - `last_crash` … 最後にクラッシュした時刻（UTC）。Sentry のイベント時刻と突き合わせれば**その端末が発生元かどうか**が確定する
  - `reports` / `attachments` … **空なら滞留なし＝取れた分は送信済み**。ここに溜まっていれば「クラッシュが止まった」ではなく「送れていない」
  - `installation_id` … 作成時刻＝この端末で native 計装が始まった時刻

  「Sentry に native crash が来なくなった」ときは、まずこの 3 つで**クラッシュが止まったのか報告が止まったのか**を切り分ける。報告側の生存確認は、crashpad バイナリ（`crashpad_handler.exe` / `crashpad_wer.dll` / `sentry.dll`）が MSIX に同梱されているかと、他プラットフォームの minidump が届き続けているかでも取れる。

- **bg task（アプリ完全終了中の push）の実機確認手順**（#474 フェーズ C / #978）。単体テストは `web_push_receive` のレイヤまでしか届かず、`push_background_task.cpp` の `Run()` だけは WinRT 依存で自動テストできないため、ここを触ったら実機で 1 往復する:
  1. MSIX を導入（上記の発行元チェックつき）し、**一度起動して終了する** — 起動時に鍵が `LocalState\push_keys.json` へ同期され、bg task が新しい DLL で再登録される。同時に未消費の観測スロットが Sentry へフラッシュされる
  2. `capsicum.exe` が終了していることを確認したうえで、**別経路（Web UI 等）から通知を 1 通発生させる**
  3. トーストが出ること、`%LOCALAPPDATA%\Packages\9AFBB08E.capsicum_8ekzzj58251a2\LocalState\push_diag.json` に `bgtask.shown` が新規記録されることを見る。アプリ未起動のまま記録されていれば in-process 受信ではなく bg task 経路と確定できる
- **Windows runner の純ロジック C++ テストは Mac の clang でも走る**。`windows/runner/notification_tag_test.cpp` / `notification_dedup_test.cpp` は Windows 固有 API に依存しないので、`cd packages/capsicum/windows/runner && clang++ -std=c++17 -o /tmp/t notification_tag_test.cpp notification_tag.cpp && /tmp/t`（dedup も同様）で macOS から検証できる（2026-08-10 実行・全通過）。テストのヘッダは `cl`（VS Developer 環境）しか案内していないため Windows CI 待ちにしがちだが、ロジックだけの変更ならここで即確認できる
- **WinRT に触る TU は「単体コンパイル」で数秒で検査できる**（`flutter build windows` を待たなくてよい）。`wns_push.cpp` / `push_background_task.cpp` のように WinRT 依存で Mac に持っていけないものは、`vcvars64.bat` を通したうえで **実ビルドと同じ厳格設定**でコンパイルだけ回す（2026-08-12 #957 で確立）:

  ```bat
  cl /nologo /c /W4 /WX /wd4100 /EHsc /std:c++17 ^
     /DUNICODE /D_UNICODE /DNOMINMAX /D_HAS_EXCEPTIONS=0 ^
     wns_push.cpp
  ```

  フラグは `windows/CMakeLists.txt` の `APPLY_STANDARD_SETTINGS` に合わせてある（`/WX` があるので警告 1 個で CI が落ちる）。CMakeLists への新ファイル追加や実際のリンクまで見たいときだけ `flutter build windows --debug` を回す（x64 実機で約 195 秒。`capsicum.exe` と `push_background_task.dll` の両ターゲットが出る）。
  - ⚠ **cmd の `cl /Fo:"%~dp0"` は壊れる**。`%~dp0` が `\` で終わるため `\"` がクォートのエスケープとして食われ、`error D8003: ソース ファイル名がありません` になる。出力先を分けたいなら `/Fo` を使わず出力ディレクトリへ `cd` してから絶対パスのソースを渡す
  - ⚠ ビルドした exe は **`.\` を付けて起動する**（この端末では cwd が exe 検索パスに入っていない）。CI (`windows-release.yml`) が `.\xxx_test.exe` と書いているのと同じ理由

### 定形作業（同期・push 前の検査）で踏むシェルの差

Windows では Claude Code の Bash ツールが Git Bash、PowerShell ツールが Windows PowerShell 5.1 になる。**手順書は macOS の書き方なので、次の 6 つだけ読み替える。**

- **`gh` は Bash ツールから叩く。**⚠ PowerShell から `gh ... --jq '...'` を呼ぶと、jq 式が空白で割られて `accepts 1 arg(s), received 4` / `unknown shorthand flag` になる（PS 5.1 のネイティブ実行ファイルへの引数の渡し方）。`curl` / `git` / `awk` / `sed` / `jq` も Bash 側でそのまま動く
- **`.claude/scripts/sentry-api.sh` は Bash ツールから動く**（使えないのは PowerShell から）。⚠ `cli issues list` には **`--org <slug>` を足す**（`~/.sentryclirc` に org が無い端末では省けない）。⚠⚠ **`post` に日本語の JSON をそのまま渡すと `'utf-8' codec can't decode` で落ちる**（Windows の curl が引数を CP932 にする）。JSON をファイルに書き、`"$(jq -c -a . file.json)"` で ASCII エスケープしてから渡す
- **PS 5.1 の `Invoke-RestMethod` は、`charset` の無い応答の日本語が化ける。**Mastodon / Misskey の API は charset 付きなので読めるが、Sentry の API は化ける。日本語を含む応答は Bash 側の `curl` で扱う
- **素の `python` / `python3` は Microsoft Store のアプリ実行エイリアスを先に掴む**（何もせず終わる）。実体を入れてあっても同じなので、`py` ランチャーかフルパスで呼ぶ
- **`.ps1` は実行ポリシーで止まる。**`powershell -ExecutionPolicy Bypass -File <script>` で 1 回だけ通す（ポリシーそのものは変えない）
- **Git Bash では `$TMPDIR` が空。**`"$TMPDIR/fmt.log"` は `/fmt.log` になって Permission denied になるので、`/tmp/` を直に書く

⚠ push 前の `dart format` が Windows で黙って空振りする件は、全 OS 共通の書き方として [CLAUDE.md「push 前のローカル整形・解析」](CLAUDE.md#push-前のローカル整形解析) に入っている（`xargs -n 40`）。

### この端末で決着した環境トラブル 2 件（記録は archive）

⚠ **どちらも解決済みで、日常の作業では踏まない。**経過・切り分けの手順・取り下げた仮説は [archive/dev-environment-windows-machine-settled.md](archive/dev-environment-windows-machine-settled.md) にある。ここには**再発したときに最初に撃つもの**だけ置く。

- **RustDesk 経由で capsicum が真っ白**（2026-08-13 決着）— 原因は**アクティブな出力がゼロになること**で、キャプチャ方式ではない。**HDMI ダミープラグ**を挿し蓋を完全に閉じる運用で解決した。⚠ **capsicum のバグではない**（Flutter の DirectComposition 面が GDI キャプチャに映らない）。再発時の最短の判定は次の 1 発で、**0 件なら出力側の問題で確定**する。capsicum も RustDesk の設定も見なくてよい。

  ```powershell
  Get-CimInstance -Namespace root\wmi WmiMonitorBasicDisplayParams
  ```

  ⚠ **ダミープラグの EDID は preferred が 3840x2160。**蓋を閉じてダミー単独になると 4K へ跳ねる。解像度の記憶は**ディスプレイ構成ごと**なので、**蓋を閉じた状態で 1920x1080 を設定し直す**。
- **WHEA（PCIe 訂正可能エラー）でイベントログが埋まる**（2026-08-13 決着）— 実害は訂正可能エラーではなく **System イベントログが埋まって障害調査が遡れなくなること**（発見時は全レコードの 95% が WHEA で、20MB の循環ログが 2.5 日で一周していた）。**PCIe の ASPM をオフ**にして停止した。⚠ **無線 LAN アダプタの無効化は選択肢に入れない**（蓋を閉じた端末にとって唯一の予備経路）。

  ```powershell
  powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
  powercfg /setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
  powercfg /S SCHEME_CURRENT
  ```

⚠ **BIOS は出荷時のまま**（1.4.1 / 2019-07-05）で、更新は保守宿題として残っている。⚠ **更新するなら蓋を開けて物理アクセスがあるときに行う** —— UEFI 段階の進行は RustDesk にもダミープラグにも出ないため、**どこにも表示されないまま進む**。

## 持ち込まないもの

- Apple toolchain（Xcode / fastlane / Apple Distribution 証明書 / `AuthKey_*.p8`）
- Android 署名鍵（`android/key.properties`）/ Google Play サービスアカウント JSON
- リポジトリルートの `.sentryclirc`（dSYM アップロード用、iOS/Android/macOS 専用）

リリース判定・ストア公開・iOS/Android/macOS の dSYM アップロードはすべてメインの macOS で行うため、補助機にこれらを置く必要はない。

