# 技術的知見・落とし穴集 — ネイティブ / CI・ビルド

[tech-notes.md](tech-notes.md) から分けた 1 本（#1184・2026-09-30）。**ネイティブプッシュ（APNs / WNS）と、CI / ビルドで踏んだ罠**を置く。

⚠ **Dart / Flutter 側の実装の罠は [tech-notes.md](tech-notes.md)、サーバー API の罠は [tech-notes-api.md](tech-notes-api.md)。**行き先の表は tech-notes.md の冒頭にある。

⚠ 端末のセットアップ・ツールチェーンそのものは落とし穴集ではなく [dev-environment.md](dev-environment.md) / [dev-environment-desktop.md](dev-environment-desktop.md)。ここには**再発する罠**だけ置く。

## ネイティブプッシュ（APNs / WNS）

### macOS ネイティブ APNs 配線の 3 つの罠（#468）

`FlutterAppDelegate`(FlutterMacOS) 上で APNs コールバックを実装する際、dart analyze も archive/署名も通るのに **実機起動でしか露見しない**罠が 3 つある（正本は [`AppDelegate.swift`](../packages/capsicum/macos/Runner/AppDelegate.swift) と [`Release.entitlements`](../packages/capsicum/macos/Runner/Release.entitlements) のコメント）:

1. **`override` 必須**: `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` は基底が `@MainActor open func` なので `override` を付ける（ヘッダに見えないので付け忘れやすい）。
2. **`super` を呼ばない**: しかし `super.application(...)` を呼ぶと基底がセレクタ未実装で `-[NSObject doesNotRecognizeSelector:]` → 起動時 SIGABRT クラッシュ。iOS は forwarding で救われるが macOS は override 側で完結させ super を呼ばない。
3. **entitlement キーが違う**: macOS は `com.apple.developer.aps-environment`（iOS の `aps-environment` ではない）。iOS 流のキーだと archive/署名は通るが runtime で `NSOSStatusErrorDomain code=13` になりトークン取得に失敗する。

クラッシュが TestFlight/debug いずれのビルドで起きたかは crash report の `procPath` で判別する。

### Windows WNS のバックグラウンド受信は AppContainer で DPAPI 境界を越えられない（#474）

WNS raw push のバックグラウンドタスクは FullTrust 本体とは別プロセスの **AppContainer サンドボックス**で走る。そのため roaming AppData の `flutter_secure_storage.dat`（DPAPI 暗号化）を復号できず、**登録も活性化も成功するのにプッシュ鍵が読めずトーストが出ない**。解法は push 鍵セットだけを平文 JSON 化して `ApplicationData.Current.LocalFolder`（パッケージ ACL 保護）へ同期し、bg task はそこから読む（macOS NSE の App Group 共有と同型。正本は [`local_state_files.h`](../packages/capsicum/windows/runner/local_state_files.h) / [`web_push_key_reader.h`](../packages/capsicum/windows/runner/web_push_key_reader.h)）。付随する汎用 Windows 罠: PowerShell の `[System.IO.File]::ReadAllText` は cwd 相対解決するので**絶対パス必須**、パッケージアプリは `%TEMP%` が `AC\Temp` にリダイレクトされる。

**観測結果を読むときの罠**: bg task は Sentry SDK を持てないため、診断コードは LocalState の単一スロットに書かれ、**次回アプリ起動時**に [`_flushWnsPushDiagnostics`](../packages/capsicum/lib/main.dart) が回収して送る。したがって `push.wns_bgtask: bgtask.shown` が Sentry に出ていないことは「トーストが出ていない」を意味しない（アプリを起動していないだけ）。**お知らせ通知の `bgtask.announcement_shown` も同じスロット・同じ遅延**で、#981 の実機到達確認ではこれを「Sentry に無い＝届いていない」と誤読しかけた。**逆に `bgtask.shown` が出ていれば表示まで成功している**（#957 以降。それ以前は `ShowRawToast` の戻り値を捨てて無条件に記録していたため、「復号は通ったが表示だけ失敗」が `shown` に化け、relay / WNS 側の不達と誤診する方向に倒れていた）。表示だけ失敗した場合は `bgtask.show_failed`、**起動中**の in-process 受信で同じことが起きた場合は `wns.show_failed`（runner が同じスロットへ書く）が warning で上がる。同様に、リレー側の `WNS notification dropped` は**端末がオフライン / スリープだった**という正常系で、件数の多さは不達の証拠にならない。Windows push の健全性は Sentry でなく **リレーサーバーの journald で成功ログと突き合わせて**判定する（手順の正本は [capsicum-relay の開発ガイド «配信不達の切り分け»](https://github.com/pooza/capsicum-relay/blob/main/docs/CLAUDE.md#配信不達の切り分けjournald-を読む)。誤診の経緯は [#931](https://github.com/pooza/capsicum/issues/931)）。

### プッシュ通知の重複は「上流の孤児購読」を先に疑う（#692）

「同じ通知が 2〜4 通届く」報告は、**リレー（capsicum-relay）でも配信基盤（APNs / FCM）でもなく、上流サーバー側に Web Push 購読（`sw_subscription`）が孤児として溜まっているのが原因**であることが多い。#692（2026-06 の実報告）はこれで確定した。

- **溜まり方はサーバー実装で違う**。ここが最重要で、**Mastodon と Misskey は非対称**（どちらも pooza フォークのソースで確認済み）:
  - **Mastodon** は `POST /api/v1/push/subscription` の `create` 冒頭で `destroy_web_push_subscriptions!` を呼ぶ（`app/controllers/api/v1/push/subscriptions_controller.rb`）。**1 アクセストークン = 1 購読**で、endpoint が変わっても置換される。再ログインで**トークンごと**変わったときだけ古いものが残る。
  - **Misskey** の `sw/register` は `(userId, endpoint, auth, publickey)` で探し（`findOneBy`・`packages/backend/src/server/api/endpoints/sw/register.ts`。**auth / publickey まで含めて一致**しないと別行）、無ければ **INSERT する**。**古い行は消えない**ので、endpoint が変わるたび（あるいは client が keyset を作り直すたび）に購読が 1 本増え続ける。
  - → **「Misskey だけで重複する」報告はこの非対称そのもの**。Mastodon 側が静かなことは、client が無実である証拠にならない。
- **relay は純粋な 1:1 フォワーダなので無実**。届いた購読ぶんだけ忠実に送る。relay のログで「複数回送信」が見えても、それは原因ではなく結果。
- **切り分け順序**: ①上流の購読テーブルを見て同一 endpoint / 同一ユーザーの行数を数える → ②relay の `subscriptions` を `device_type` 別に「行数 / 実アカウント数」で割り、**プラットフォーム間で比を比べる**（突出しているものが endpoint を作り直している）→ ③孤児を整理して再現するか見る。iOS と Android で症状が違って見えても**同根**のことがある（#692 がそうだった）。

**⚠ 「client 側の修正では直らない」と決めつけない（2026-08-05 に反例が出た）。**#692 の時点ではそう書いていたが、[#937](https://github.com/pooza/capsicum/issues/937) は **client が孤児を作っている側**だった —— push の endpoint は `${relayBaseUrl}/push/${push_token}` で、`push_token` は relay の行（`UNIQUE(token, account, server)`、`token` はデバイストークン）が新規作成されたときだけ発行される。**再起動をまたいでデバイストークンが変わると新しい endpoint になるが、起動経路は古い endpoint を unregister しない**（プロセス内のローテーションは `_runTokenRefresh` が正しく掃除するのに、再起動をまたぐ変化はその経路に乗らない）。Windows は WNS の channel URI が変わりやすく、relay 実測で **86 行 / 20 アカウント = 4.3** と他プラットフォーム（iOS 2.05 / Android 1.9 / macOS 1.6）から突出していた。

**⚠ この 4.3 を endpoint churn だけに帰さないこと（[#950](https://github.com/pooza/capsicum/issues/950)）。** 掃除側も効いていなかった —— `_cleanupDeviceRegistration` は「全アカウントを `unregisterAccount` → 最後に `unregisterDevice`」の順で回すが、前段の `PushKeyStore.delete(accountKey)` が **`relayId` スロットごと消す**ため、後段は保存済み id を 1 つも見つけられず `DELETE /register/:id` を**一度も発行していなかった**。孤児が増える一方で、アプリから relay row を消す経路が実質存在しない状態。加えて doc / 実装が `UNIQUE(token)`（**旧**スキーマ）の「1 行消せばデバイス全体が消える」前提のままで、現行の `UNIQUE(token, account, server)` では **N アカウント中 1 行しか消えない**形でもあった。両方 v1.55 で是正済み。

恒久対処は上流側（モロヘイヤ [#4408](https://github.com/pooza/mulukhiya-toot-proxy/issues/4408) が `sw/register` を `(userId, endpoint)` 単位で dedup）＋ relay 側の保険 dedup（[capsicum-relay#16](https://github.com/pooza/capsicum-relay/issues/16)）＋ **client 側の endpoint 安定化**（[#932](https://github.com/pooza/capsicum/issues/932) の device-id + [capsicum-relay#15](https://github.com/pooza/capsicum-relay/issues/15)）。

## CI / ビルド

### `set -o pipefail` + 早期終了するパイプは、判定を「合致したときだけ false」に反転させる

シェルで書いた**判定**が、入力が大きいときだけ逆さまに壊れる罠。v1.61 のリリースで実踏し（#1036）、その後の掃き出しで `distribution/linux/install.sh` にも同型が残っていた。

```sh
set -euo pipefail
if printf '%s' "$msgs" | grep -qiE 'chore\(deps\)'; then   # ⚠ 壊れる
```

`grep -q` は**マッチした時点で即座に終了する**。すると書き込み途中の `printf` が SIGPIPE で落ち、`pipefail` によってパイプライン全体の終了ステータスが非ゼロになる。`if` はパイプラインの終了ステータスを見るので、**マッチしたときに条件が false になる**。マッチしなければ grep は入力を最後まで読むので、`printf` は正常終了して判定も正しく false になる。つまり**「合致しない」だけが正しく動く**。

⚠ **入力が小さいと再現しない。**パイプバッファ（64KB）に書き切れてしまうため。再現には「**マッチが先頭近く + 後ろに大量のデータ**」の両方が要る。`git log` は新しい順に出すので、「直前に印を付けたコミットを積んで、まとめて大きな push をする」形でだけ落ちる。

⚠ **zsh では再現しない。**手元で試して再現しなかったことを「バグではない」と読み替えないこと。確認は bash で行う。

```sh
bash -c 'set -euo pipefail
msgs="$(echo "chore(deps): bump"; head -c 300000 /dev/zero | tr "\0" "x")"
if printf "%s" "$msgs" | grep -qiE "chore\(deps\)"; then echo OLD:matched; else echo "OLD:NOT matched (誤爆)"; fi
if grep -qiE "chore\(deps\)" <<< "$msgs"; then echo NEW:matched; else echo "NEW:NOT matched"; fi'
```

**対処**: **grep にファイルを直接読ませる**のが一番強い。パイプを挟まない限りこの罠は構造的に踏めない。パイプが避けられない場所では herestring (`<<<`) を使う（**書き手が bash 自身になるので、読み手が早期終了しても「シェルが SIGPIPE で落ちる」形にならない**）。⚠ **「herestring は常に一時ファイル経由」という理解は bash 5.1 以降では正しくない** — 中身がパイプバッファに収まるならパイプを使い、収まらないときだけ一時ファイルに落ちる。どちらの経路でも上のコマンド置換 + パイプのような「上流のプロセスが SIGPIPE で殺されて `pipefail` が非ゼロを返す」形にはならないので、**結論は変わらないが根拠を版に依存させない**。同じことが `grep -m1` / `head -n` を**パイプの下流に置いた**場合にも起きる（下流が先に終了して上流を殺す）ので、件数の絞り込みは `grep -m1 <file>` のようにパイプを挟まない形へ寄せる。

### 大きな入力を環境変数・引数で渡すと Linux でだけ落ちる

上のガードを切り出したとき、判定への入力を環境変数（`MSGS="$msgs" bash guard.sh`）で渡して CI を赤くした。

```
lock_guard_selftest.sh: line 31: /usr/bin/bash: Argument list too long
```

Linux の `execve` は**引数・環境変数を 1 つあたり 128KB**（`MAX_ARG_STRLEN`）までしか通さず、超えるとプロセスの起動自体が失敗する。⚠ **macOS は上限が緩く、手元では最後まで再現しない。**上の SIGPIPE 罠と同じ「開発機では通って CI でだけ落ちる」形。

厄介なのは、**これがまさにガードの想定場面で起きる**こと。`git log` の出力はコミット数の多い push で普通に 128KB を超える。「小さいときだけ動く」検査は、いちばん要るときに動かない。

**対処**: 中身ではなく**ファイルのパス**を渡す（`MSGS_FILE="$work/msgs"`）。シェル変数への代入自体には上限が無いので、`printf '%s\n' "$msgs" > file` で落としてからパスを渡せばよい。grep もファイルを直接読める形になるので、上の SIGPIPE 罠も同時に消える。

⚠ **`while IFS= read -r x` でファイルを読むときは `|| [ -n "$x" ]` を付ける。**`read` は EOF で非ゼロを返すため、**末尾に改行が無いファイルの最終行が丸ごと無視される**。1 行だけのファイルなら中身が全部消え、「対象なし・OK」と言って素通りする＝ fail-open になる。herestring で渡していた頃は bash が改行を足していたので表に出なかった。

⚠ **`|| true` が付いていると無害に見えるが、依存していると気付かない。**`X=$(a | grep -m1 b || true)` は、grep が終了前に stdout を出しているので値は正しく、`|| true` が `set -e` を打ち消す。動くが、`|| true` が load-bearing であることが読み取れない。書き換えておく。

⚠ **`#!/bin/sh` で `set` を書いていないスクリプトは影響を受けない**（pipefail が無いので `if` は末尾の grep だけを見る）。`.claude/hooks/deny-shell-loops.sh` がこれ。ただしここに pipefail を足すと、**ループを検出できたときに限って素通りする**ガードになる。dash 互換のため herestring へ寄せられないので、「足さない」ことで担保している。

**ガードは自分自身を検査させる。**この種のバグは「ガードが間違った方向に壊れる」形で出るため、正しい手順を踏んだ人が「規約どおりにやったのに怒られる」状態になり、規約そのものへの信頼が落ちる。判定を `.github/scripts/lock_guard.sh` へ切り出し、`lock_guard_selftest.sh` が毎 push 回している。切り分けの基準は「環境が無いと再現できるか」で、**どの範囲を見るか**（GitHub のイベントが要る）は workflow に残し、**通すか落とすか**（純粋な判定）だけをスクリプトへ出す。検査は「落ちるべきときに落ちる」だけでなく「**通るべきときに通る**」も見ること。セルフテストは第 1 引数で対象を差し替えられるので、壊れた実装を食わせて**検査に歯があること**を確認できる。

### Windows: mpv アーカイブの `Integrity check failed` は一過性（再実行で通る）

`windows-release.yml` の msix ジョブが、Dart のコンパイルより手前の CMake 段階で落ちることがある。

```
CMake Error at flutter/ephemeral/.plugin_symlinks/media_kit_libs_windows_video/windows/CMakeLists.txt:43 (message):
  .../build/windows/x64/mpv-dev-x86_64-20230924-git-652a1dd.7z
  Integrity check failed, please try to re-build project again.
```

`media_kit_libs_windows_video` がビルド時に外部から取得する mpv の `.7z` が壊れていて、チェックサム検証に落ちた状態。**コード起因ではない。**`gh run rerun <id> --failed` で通る（2026-08-18 の v1.58 リリース PR で実測。1 回目 5m31s で失敗 → 再実行 17m23s で成功）。

⚠ **切り分けの手がかり**: 失敗地点が **Dart のコンパイルより前**なら、その run のコード差分は無関係とみてよい。同じツリーの直前の run が通っていればほぼ確定。

Linux 側は `libmpv-dev` を apt で入れるので、この経路は Windows 固有。**2 回続けて落ちたら一過性ではない**ので、media_kit の配布元（GitHub Releases）側か runner のネットワークを疑う。

### Windows ネイティブを触ったときの検証手順（#995 / #997 で確立）

⚠ **`develop` の CI では C++ が 1 行もコンパイルされない**（`analyze.yml` は Dart のみ）。`windows-release.yml` は native テスト **8 本すべて**をビルド・実行するが、**tag ビルドのときだけ**走る。そして **`wns_push.cpp` はどのテストにも含まれず、フルビルドでしか通らない**。つまり `windows/runner/**` を触った変更は、**実機で回すまで一度もコンパイルされないまま develop に入りうる**。

Windows 実機（[プラットフォームゲート](CLAUDE.md)の x64 端末）では次を回す:

1. **native テスト 8 本** — `vcvars64.bat` を call してから `cl /nologo /EHsc /std:c++17 <name>_test.cpp <name>.cpp`。⚠ **`notification_tag_test` だけ `/utf-8` が要る**。⚠ **cmd から exe を叩くときは `".\name.exe"` と書く**（cwd を PATH 探索しない）
2. **`cd packages/capsicum && flutter build windows --debug`** — **`wns_push.cpp` に触ったらこれが唯一のゲート**（約 5 分）。`firebase_app` の `LNK4099` 警告は既存ノイズ
3. `dart format --set-exit-if-changed .` / `dart analyze --fatal-infos` / `flutter test`。⚠ **`flutter build` 後の format は `packages/capsicum/build/` 配下の生成 Dart を拾うが gitignore 済みなので無視してよい**

⚠ **単一スロットの push 観測にコードを足すときは 2 箇所を同時に直す。** `windows/runner/push_diagnostics.cpp` の `IsBenignCode` と `packages/capsicum/lib/main.dart` の `benign` 集合は必ず揃える。片方だけだと、正常系のはずのコードが平常時の端末から毎回 warning で上がる（#997 の `wns.announcement_deduped` がその形だった）。⚠ **この一致を守る自動テストは無い**（コメントで揃えろと書いてあるだけ・[#1012](https://github.com/pooza/capsicum/issues/1012) に起票済み）。

### 手元でビルドした exe を、Store 版のパッケージ ID の中で走らせる（#1248 で確立）

⚠⚠ **「Windows の課金は製品版でしか確かめられない」は誤りだった。**Microsoft Store から入れた capsicum がある端末なら、**手元の exe にそのパッケージの ID とライセンスを貸して起動できる**。`StoreContext` は本物の Store へ繋がり、商品も返る。

```powershell
Invoke-CommandInDesktopPackage -PackageFamilyName '9AFBB08E.capsicum_8ekzzj58251a2' `
  -AppId 'capsicum' -Command '<exe の絶対パス>' -Args '<引数>' -PreventBreakaway
```

- 前提は**開発者モードが ON** であることと、Store 版が入っていること（`Get-AppxPackage 9AFBB08E.capsicum` の `SignatureKind` が `Store`）。入っているパッケージは置き換わらない
- **`-Command` は何でもよい。**`powershell.exe` を渡せば WinRT を数行で叩けるし、`cl` で作った数十行の exe でも、`flutter build windows` の `capsicum.exe` でもよい。⚠ **小さいものから順に試す** —— #1248 は「PowerShell から 1 秒で返る → 呼び方を写した小さな exe でも返る → 本物の exe でだけ届かない」の 3 段で、Store・呼び方・プロセスの中身を切り分けた
- ⚠ **標準出力は取れない**（切り離されて起動する）。記録はファイルへ書く。⚠⚠ **書き先は `%USERPROFILE%` の直下にする** —— `AppData` の下はパッケージごとの場所へ付け替えられることがあり、書いたはずのファイルが見つからない
- ⚠⚠ **`capsicum.exe` を走らせると、Store 版と同じ利用者データ（`%APPDATA%\net.shrieker\capsicum`）を読み書きする。****入っている版と同じタグからビルドする**（develop の exe は DB や設定を先へ進めてしまい、Store 版へ戻れなくなりうる）。`RELAY_SECRET` も `--dart-define` で渡す（渡さないとプッシュの登録が 401 になる）
- 🔴 **購入の API（`RequestPurchaseAsync`）は呼ばない。**本物のライセンスなので、本当に課金される

⚠ **#1248 の原因はこの経路で 1 時間ほどで出た。**`Win32Window::Create()` は**ウィンドウを作る前に必ず `Destroy()` → `OnDestroy()` を通る**（Flutter のテンプレートの作り）。`OnDestroy` で倒したフラグを `OnCreate` で立て直さないと、**起動した時点から「破棄済み」のまま**になる。⚠⚠ **`OnDestroy` は「終了時に 1 回だけ走る」関数ではない。**再発は [`windows_window_alive_guard_test.dart`](../packages/capsicum/test/windows_window_alive_guard_test.dart) で止めている。

### native テストの大半は macOS でも走る（`windows.h` の最小シム・#1014）

上の「実機で回すまで一度もコンパイルされない」は **`wns_push.cpp` のような WinRT 依存のファイルに限った話**。`notification_dedup` のような**純粋なロジック**は Win32 API をほとんど使っておらず、`windows.h` を 1 ファイルで代替すれば macOS の clang でそのままビルド・実行できる。**Windows 端末が空くのを待たずにロジックの誤りを潰せる**ので、実機は「本当に WinRT が要る検証」だけに使う。

```sh
mkdir -p /tmp/winshim && cat > /tmp/winshim/windows.h <<'EOF'
#pragma once
#include <cstdio>
inline void OutputDebugStringA(const char* s) { std::fputs(s, stderr); }
EOF
cd packages/capsicum/windows/runner
clang++ -std=c++17 -I/tmp/winshim -o /tmp/dedup_test \
  notification_dedup_test.cpp notification_dedup.cpp && /tmp/dedup_test
```

⚠ **シムで通ったことは「Windows でビルドできる」の保証にならない。** MSVC は clang より緩い / 厳しい箇所がそれぞれあり、`/utf-8` の要否（`notification_tag_test`）のような MSVC 固有の問題は素通りする。**実機の手順 1〜2 を省略してよいわけではなく、実機へ持ち込む前に落とせるものを落とすための手**。

⚠ **シムに関数を足したくなったら、それはもう「純粋なロジック」ではない。** 対象ファイルが Win32 / WinRT へ依存し始めた合図なので、シムを厚くするのではなく実機ビルドへ回す。

### `.ps1` に日本語を書くと無音で構文エラーになる（PowerShell 5.1）

Windows 機で `.ps1` を書いて `powershell.exe -File` で実行するとき、**BOM 無し UTF-8 の日本語が含まれると PowerShell 5.1 が ANSI (CP932) として読み**、文字列リテラルが壊れて `The string is missing the terminator: ".` で落ちる。

⚠ **失敗が無音になる。**`Start-Process -Verb RunAs -Wait` で昇格実行すると、パースエラーは昇格した子プロセス側で起きるため親からは成功に見える（`-WindowStyle Hidden` なら画面にも出ない）。ログの 1 行目すら書かれないので、**「UAC が承認されていない」と誤診しやすい**。

⚠ **静的な検査は通ってしまう。**`[System.Management.Automation.PSParser]::Tokenize()` に `[IO.File]::ReadAllText()` の結果を渡す形だと、.NET が UTF-8 を自動判別するので再現しない。切り分けは**非昇格で 1 回 `powershell.exe -File` を走らせて exit code と stderr を見る**のが速い。

回避は **スクリプト本体を ASCII のみで書く**（コメントも英語）。日本語が要るなら UTF-8 **BOM 付き**で保存する。1 行で済むならファイルを経由せず直接渡せば影響を受けない。

