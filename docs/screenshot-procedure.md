# ストア用スクリーンショットの撮り方

**何をどの順で撮るか**は [store-listing.md](store-listing.md) の「スクリーンショット」節が正本。ここは**撮り方**（道具・下準備・手順・落とし穴・後始末）を持つ。初回の経緯は [#1311](https://github.com/pooza/capsicum/issues/1311)。

⚠⚠ **目的は「撮り直しをすぐできること」**（2026-10-21 pooza）。UI が変わるたびに撮り直すので、1 回目に踏んだ罠をここに全部残す。

## いつ撮り直すか

**リリースのたびに見直す**（[store-release スキル](../.claude/skills/store-release/SKILL.md) §4.0-2）。⚠ App Store は**版の提出のときにしか差し替えられない**ので、提出の直前に気付いても間に合わない。

判断の基準:

- その版の変更が、**撮っている画面**（並び順の表の各項目）に見た目で効くか
- 入力欄のヒント・ボタン・バーなど、**どの画面にも写る部品**が変わったか（例: v2.5 で簡易投稿バーのヒントが「…でキュア！...」に変わった）

⚠ **全部を撮り直す必要はない。**効く画面だけを撮り直す。揃っていなくても困らない程度の差なら、その版は見送ってよい（pooza）。

## 道具（tool/screenshot）

| スクリプト | 用途 |
| --- | --- |
| [`fedi.sh`](../tool/screenshot/fedi.sh) | 撮影用の `@test` を API で操作する（トークン・プロフィール・フォロー・投稿・リアクション・後始末） |
| [`sim.sh`](../tool/screenshot/sim.sh) | iOS シミュレータを操作して撮る（`SIM=iphone` / `SIM=ipad`） |
| [`mac.sh`](../tool/screenshot/mac.sh) | macOS の capsicum を操作して撮る・矩形をぼかす |
| [`android.sh`](../tool/screenshot/android.sh) | Android の実機を adb で操作して撮る |
| [`win.ps1`](../tool/screenshot/win.ps1) | Windows の capsicum を操作して撮る・矩形をぼかす（PowerShell） |
| [`simtap.swift`](../tool/screenshot/simtap.swift) / [`blur.swift`](../tool/screenshot/blur.swift) | クリック・キー送出 / 矩形のぼかし。初回に `$SHOT_DIR/bin` へ自動でビルドされる |

作業用の置き場は `$SHOT_DIR`（既定 `~/.cache/capsicum-screenshot`）。トークン・撮影ログ（`posted.log` / `reacted.log`）・撮った画像・アイコン（`avatar.png`）を置く。⚠ トークンを置くので**リポジトリの外**にしてある。

撮った画像の保管先は共有ドライブの `capsicum/screenshots/<版>/<枠>/`（メンテナ向け）。

## 撮影用のアカウント

各プリセットサーバーの `@test`（美食丼・デルムリン丼・キュアスタ！・ダイスキー。きゅあすきーは対象外）。ログイン情報は `secrets.env` の `TEST_<KEY>_EMAIL` / `TEST_<KEY>_PASSWORD`。

**いまの状態（そのまま残す）**:

- 表示名は「capsicum」、アイコンはアプリのアイコン
- 4 台が互いにフォローしている（お知らせボットへのフォローは残す）。@pooza はフォローしない
- キュアスタ！の `@test` は、ボットの @makoto と @mikabot を**ミュートしている**。`#precure_fun` に定期的に投稿してきて、撮るたびに割り込むため（他の人の投稿と、ファンアートのアイコンが写る）
- Annict は @pooza の Annict アカウントを、キュアスタ！の `@test` に連携してある
- ⚠ **bot の印は撮影の間だけ外す**（capsicum は bot の投稿にロボットの印を出す）。撮り終えたら戻す

⚠⚠ **`@test` への書き込みは本番の Mastodon / Misskey への書き込み。**`fedi.sh` の `show` 以外は、着手前に pooza の承認を取る。

### トークン

```sh
tool/screenshot/fedi.sh token CURESTA     # Mastodon の 3 台（BSHOCKDON / DELMULINDON / CURESTA）
```

- ⚠ Mastodon は password grant が無効。`fedi.sh` は Web のログイン → 認可コードの流れを curl で辿る
- ⚠ **ダイスキーはサインインに Turnstile が掛かっていて、API からは取れない。**DB から `@test` のトークンを読み取りで引き、`$SHOT_DIR/tokens/DAISSKEY` に置く（接続先と DB の扱いは chubo2 の docs・private）。⚠ トークンを画面に出さず、ファイルへ直接書く

## 下準備（毎回）

1. **Mac の画面ロックを解除しておく。**ロック中は、どのアプリの窓もアクセシビリティから見えず、クリックも届かない（`ioreg -n Root -d1 | grep IOConsoleLocked` が `Yes`）。⚠ 解除だけは pooza に頼む。解除したら `caffeinate -d -t 14400` を流して画面を寝かせない（既定は 5 分）
2. **bot の印を外す**（承認を取ってから）: `fedi.sh bot <KEY> false` を 4 台
3. **撮影用の投稿を作る**（下の「撮影用の投稿」）

## iPhone / iPad（シミュレータ）

```sh
SIM=iphone tool/screenshot/sim.sh boot   # 起動・ステータスバー・（iPad は横向き）
SIM=iphone tool/screenshot/sim.sh fit    # DeviceHub の窓を決まった位置に置く
tool/dev-run.sh -s -d <UDID>             # 初回だけ debug ビルドを入れる
```

| 枠 | 機種 | 寸法 |
| --- | --- | --- |
| iPhone | iPhone 18 Pro Max | 1320×2868（6.9 インチ） |
| iPad | iPad Pro 13-inch (M5)・横 | 2752×2064 |

⚠⚠ **App Store Connect の iPhone の枠は、2026-10 の時点で「Dynamic Island 搭載 iPhone（中型ディスプレイ）」の 1 つだけ**になっていて、受け付けるのは **1179×2556 / 1206×2622**（6.1 / 6.3 インチ）。⚠ **6.9 インチの 1320×2868 は「サイズが無効です」で弾かれる**（v2.5 の提出で踏んだ）。撮るのは 6.9 インチのままにして、貼る前に縮める（縦横比はほぼ同じで、横が 1 画素はみ出すだけ）:

```sh
sips --resampleHeight 2622 iphone-6.3/*.png
sips --cropToHeightWidth 2622 1206 iphone-6.3/*.png
```

⚠ **画面から消えた 6.5 インチの枠も、API の上では版に残る**（v2.5 では 2026-03 の古い 4 枚が載ったままだった）。貼ったあとは `.claude/scripts/asc-status.rb screenshots` で、版に載っている枠と枚数を確かめる。⚠ 画面に無い枠の画像は App Store Connect の画面から消せないので、API（`DELETE /v1/appScreenshotSets/{id}`）で消す。

⚠ **debug ビルドで撮る**（シミュレータでは release が動かない）。画面に「debug」は出ないが、**通知のバナーにはアプリ名「capsicum (debug)」が出る**ので、プッシュ通知は iPhone の枠から外してある。

### 操作のしかた

```sh
SIM=iphone tool/screenshot/sim.sh tap 86 268       # 画素座標（スクショの座標）をタップ
SIM=iphone tool/screenshot/sim.sh shot s01         # 撮って縮小版の場所を出す
```

**1 手ごとに撮って確かめる。**座標は画面の状態で変わる（アカウントが増えるとドロワーの「アカウントを追加」が下がる・ダイアログの位置がサーバーで違う）。⚠ 縮小版の座標に、縮小率（iPhone なら 2868/900）を掛けて画素座標にする。

### 落とし穴

- **Xcode 27 は Simulator.app ではなく DeviceHub**（`Xcode.app/Contents/Applications/DeviceHub.app`）。窓の一覧の行は、座標のクリックでは選べない。AX で `set selected of row N of outline 1 of …` する。表示は「ウィンドウに合わせる」で拡大する
- ⚠ **System Events の `click at` はシミュレータの画面に効かない**（-25204）。`simtap`（CGEvent）で押す
- ⚠ **`simctl pbcopy` が効かない**（入れた直後でも空）。貼り付けは使わず、キー入力で入れる
- ⚠⚠ **iOS の言語が日本語だと、Mac のキー入力がローマ字かな変換される**（Mac の入力ソースは関係ない）
  - **英字だけの欄**（ログイン・認可コード）: `sim.sh lang en` で英語にしてから打ち、終わったら `sim.sh lang ja`
  - **日本語の欄**: ja のまま、ローマ字を `type` → `key 49`（スペース）で変換 → 候補をタップするか `key 36`（Return）で第一候補を確定。`,` は「、」、`.` は「。」になる
- Safari などから戻ると、ステータスバーの左上に「◀ Safari」が残る。`sim.sh app` で終了して開き直すと消える
- 再起動するとステータスバーの上書きと、iPad の横向きが外れる。`lang` と `boot` は掛け直す
- iPad の画面分割: 窓の左上の信号ボタンの**緑を長押し** →「移動とサイズ変更」で左右に寄せる。⚠ 押す位置がずれて閉じる・最小化に当たることがある。iPad のホーム画面ごと落ちたら、`boot` を掛け直してアプリを開き直す
- ログインは「ブラウザでログイン」→ アプリ内のブラウザ。パスワードの保存は「今はしない」。ダイスキーは Turnstile が自動で通る

### Annict

キュアスタ！の `@test` に連携済みなので、そのアカウントで開けば感想の画面に直接入れる。連携し直すときは、エピソードブラウザの「Annict と連携」→ Safari で認可 → 表示された認可コードを、capsicum に戻って入力する。⚠ **認可コードは使い切り**。pooza から受け取るなら `secrets.env` の `ANNICT_AUTHCODE` に入れてもらい、`typesecret` で打つ。

### ナウプレ（iOS）

シミュレータには**ミュージックアプリが無い**ので、♪ボタンの差し込みは撮れない。Safari で Apple Music の曲のページ（`https://music.apple.com/jp/song/<id>`）を開き、「共有」から capsicum へ渡す。⚠ 本文の URL は日本語のエンコードで長くなる。投稿後には切り詰められるが、画像では伝わらないので、**撮る前にエンコード部分を消す**（`/album/` の後ろの `%E3…/` を Delete で消す）。

## Mac

```sh
tool/dev-run.sh -s -d macos
tool/screenshot/mac.sh fit       # 1440x900（Mac App Store の 16:10）
tool/screenshot/mac.sh tap 112 443
tool/screenshot/mac.sh paste 'ハロウィン回、衣装がどれも可愛かった。'
tool/screenshot/mac.sh shot m01
```

- ⚠ **debug 版とストア版は、バンドル ID もデータの置き場も同じ。**debug 版で撮影用にアカウントやデッキを組み替えると、ストア版にも反映される。Mac のストア版・TestFlight 版は書き換えてよい（pooza）。⚠ **普段遣いの miki の Linux 版と Pixel 8 は書き換え禁止**
- **ログインは既定のブラウザ（Vivaldi）で開く。**pooza のブラウザに `@test` のログイン情報を打つので、⚠ **auto モードでは拒否される**（手動モードに切り替えてもらう）。⚠ **撮り終えても Vivaldi の `@test` のログインは残す**（2026-10-22 pooza・次の撮影でログインし直さずに済む）
- 日本語は `paste`（クリップボード経由）で入れる。⚠ pooza のクリップボードを上書きする
- ファイルを選ぶダイアログ: Cmd+Shift+G → パスを打って Return 2 回
- ⚠ `osascript` で Safari を `tell` すると、macOS が「VS Code が Safari を制御する」許可を求める。URL を開くのは `open -a Safari <url>`、窓の位置は System Events で動かす（Safari の許可は要らない）
- 動画の横の実況: Safari（幅 800）と capsicum（幅 640・これより細くならない）を並べ、画面の範囲を `screencapture -R 240,60,1440,900` で撮る。⚠ YouTube は予告が終わると**次の動画へ自動で進む**ので、再生中に撮る
- ナウプレ: ミュージックで曲を再生してもらい、♪ボタンで入れる（ジャケット付き）。URL は iOS と同じく撮る前に短くする

## Play（Android の実機）

**検証機の Pixel 6a で、Play から入れた製品版のまま撮る**（2026-10-21 pooza）。⚠ 普段遣いの **Pixel 8 は使わない**（書き換え禁止）。

```sh
export ANDROID_SERIAL=<serial>          # adb devices
tool/screenshot/android.sh demo on      # ステータスバーを 10:00・電池満タン・通知なしに
tool/screenshot/android.sh app          # capsicum（net.shrieker.capsicum）を前面に
tool/screenshot/android.sh tap 540 1187 # 画素座標
tool/screenshot/android.sh shot a01
tool/screenshot/android.sh demo off     # 撮り終えたら戻す
```

- 1080×2400（9:20）。⚠ 縮小版（高さ 900）の座標は **2.667 倍**して画素にする（係数を間違えて別の項目を押したことがある）
- ⚠ **手元でビルドした release は入らない。**Play の版は Play の鍵で署名されていて上書きできない（消すとアカウントと設定が消える）。v2.5 との違いが撮る画面に効くときは、Play の内部テストに上がってから撮る（2.5 は 10-22 に撮影のために 207 を内部テストへ上げた）
- ⚠ **内部テストに上げても、ストアのページが古いまま「開く」しか出ないことがある**（10-22 は 10 分たっても出なかった）。検証機なら `adb shell pm clear com.android.vending` で Play ストアのデータを消して開き直すと、すぐ「更新」が出た
- ⚠ **BACK の押しすぎに注意。**Play ストアから capsicum を開いた直後は、BACK でアプリを抜けて Play ストアへ戻る（次のタップがストアの画面に当たる）
- **入力**: `adb shell input text` は ASCII だけ。⚠ 長い文字列は途中で落ちることがあるので、パスワードは **4〜6 文字ずつ**区切って送り、件数を伏せ字の数で確かめる。⚠ Gboard の Ctrl+A は効かない。消すときは Delete（`keyevent 67`）を並べる
- **日本語**: Gboard を「あ」にして、ローマ字を `type` → `key SPACE` で変換 → `key ENTER`。⚠ 長く打つと変な区切りで変換されるので、**言葉ごとに**変換・確定する
- **ログイン**: Chrome で開く。Bitwarden の保存は「いいえ」。戻り先は「capsicum」と「capsicum (debug)」の両方が出るので、**capsicum を「1 回のみ」**で選ぶ。ダイスキーは Chrome に @pooza のログインが残っているので「アカウントを追加 → 既存のアカウント」で `@test` に入る
- **プッシュ通知**: ダイスキーの `@test` を入れ、設定 → プッシュ通知で「登録済み」を確かめる。別のサーバーの `@test` から `fedi.sh react <KEY> fav <ダイスキーのノートの URL>` で送り、`adb shell cmd statusbar expand-notifications` で引き下ろす。⚠ 引き下ろすとデモ表示が外れて**実機の時刻と日付が写る**（pooza の端末なので構わない）。他のアプリの通知は消してよい（検証機）
- **添付画像**: `adb push` で `/sdcard/Pictures/` に置くと、写真の選択の先頭に出る
- **共有から作るナウプレ**: YouTube Music の曲の「⋮ → 共有 → 他のアプリと共有 → capsicum」。⚠ 渡るのは URL だけなので、本文は `#nowplaying <URL>` の 1 行になる（曲名はモロヘイヤが投稿時に足す）

## 撮影用の投稿

⚠ **他の人の投稿・アイコンを写さない。アニメのキャプチャや公式の絵を写さない**（store-listing.md）。

### 実況（タグのタイムライン）

1. **実況用のタグセット**を `@test` に設定する。アプリの番組表が送るのと同じコマンドを、ダイレクトで投稿する（モロヘイヤの `user_config`。30 分で外れる）:

   ```yaml
   command: user_config
   tagging:
     user_tags:
     - 名探偵プリキュア！
     - 実況
     - 39話
     - おジャ魔女なハロウィン♪
     minutes: 30
   decoration:
     minutes: 30
   ```

   番組と話数は `curl -s https://precure.ml/mulukhiya/api/program` で、いま放送している回を引く。

2. **本文にハッシュタグを打たない。**既定のタグ（`#precure_fun` など）はモロヘイヤが付ける（pooza）。⚠ キュアスタ！のタグに載せたいなら、キュアスタ！の `@test` から投稿する（他のサーバーでは既定のタグが違う）
3. **15〜20 秒おきに、実況の流れの順に**投稿する（新しい順に並ぶので、画面の上が最後の投稿になる）。CM の話題は、**マクドナルドのプリキュアのハッピーセット**か、**「たのしい幼稚園」の付録のプリキュア目覚まし時計**に絡める（pooza）
4. 画面の一番上に他の人の投稿が来たら、`@test` の投稿を足して押し出す

### デッキ

カラムごとに別のアカウントにする（タブ表示との違いが出る）。**タグのタイムラインは使わない**（他の人が流れ込む）。v2.5 の組み方:

| カラム | 中身 |
| --- | --- |
| 1 | キュアスタ！のホーム |
| 2 | 美食丼の通知（他の 3 台からのお気に入り・ブースト・フォロー） |
| 3 | ダイスキーのホーム |

- 美食丼の投稿は**他愛のない日常の話**にする（美食丼のテーマはグルメと関係ない・pooza）。デルムリン丼・ダイスキーは「ダイの大冒険」の話題
- 通知は `fedi.sh react` で付ける。⚠ **ダイスキーからリアクションを付けると、モロヘイヤが「リアクション ❤️ を送りました」という返信ノートを `@test` の名前で自動投稿する**（ホーム公開）。写るので消す。ボットからのメンションの通知も、撮る前に外す

## 後始末

- ⚠ **撮影用の投稿・リアクションは消さない**（2026-10-21 pooza）。利用者には「スルーするなりミュートするなりしてください」と伝えてある。`fedi.sh cleanup`（`posted.log` の投稿を消し、`reacted.log` のリアクションを外す）は、消す必要が出たときのために残してある
- bot の印を戻す（承認を取ってから）: `fedi.sh bot <KEY> true` を 4 台
- ⚠ ミュート・相互フォロー・表示名・アイコン・Annict の連携・Mac の Vivaldi の `@test` のログインは**残す**（次の撮影でも使う）

## Windows

x64 の Windows 機で、develop の debug ビルドを撮る（2026-10-21 が初回）。道具は [`win.ps1`](../tool/screenshot/win.ps1)（PowerShell。撮る・クリック・キー・日本語入力・窓の配置・ぼかし）。

```powershell
powershell -ExecutionPolicy Bypass -File tool\dev-run.ps1 -d windows         # 初回だけ。以後は build の Debug\capsicum.exe を直接起動してよい
powershell -ExecutionPolicy Bypass -File tool\screenshot\win.ps1 place '@app' 240 100 1440 810
powershell -ExecutionPolicy Bypass -File tool\screenshot\win.ps1 shot w01 240 100 1440 810
```

- 寸法は 1440×810（16:9・Store の下限 1366×768 より大きい）。窓をこの大きさに置き、その矩形を撮る
- ⚠ **`@app` で capsicum の窓を指す。**VS Code にも「capsicum」という題の窓があり、題で探すと取り違える
- **ログイン**: Vivaldi のプライベートウィンドウで `@test` に入る（Ctrl+Shift+N に OAuth の URL を貼る）。打つのは `win.ps1 typesecret TEST_<KEY>_EMAIL` / `_PASSWORD`（値を画面に出さない）。ダイスキーの MiAuth は時間が経つと戻り先に届かないので、止まったらやり直す
- ⚠ **実況を隠す設定（ヘッダーのマイクのボタン）が ON だと、実況の投稿がタグの TL に出ない。**撮るあいだだけ OFF にして、撮り終えたら戻す
- 入力: 日本語は `win.ps1 type <UTF-8 のファイル>` で入る。⚠ **Ctrl+A・Ctrl+Home は capsicum の入力欄に効かない。**消すときは本文の下の空白をクリックして末尾に置き、`key '{BS 50}'` を並べる
- 投稿画面を開くのは簡易投稿バーの右の展開ボタン（Ctrl+N はタブ表示では効かなかった）。タイムラインの更新は Ctrl+R
- 動画の横の実況: Vivaldi（幅 800）と capsicum（幅 640）を並べて 1440×810 を撮り、`win.ps1 blur` で左の 800 を窓ごとぼかす。YouTube は `k` で止める
- ナウプレ: Spotify で、**ジャケットがアニメの絵でない曲**を流す（2026-10-21 は久石譲「ENCORE」）。曲送りは `win.ps1 vk 176`。⚠ **同じプロセスで ♪ を続けて押すとジャケットが付かなくなる**（[#1329](https://github.com/pooza/capsicum/issues/1329)）ので、付かなければアプリを起動し直して 1 回で入れる。下書きが残っていると「前回の入力を復元しました」の帯が写るので、本文を空にしてから起動し直す
- 添付画像の編集: 下地は手元で描いた絵を使う（権利の心配が無い）。スタンプは他社のロゴを避ける
- Vivaldi は窓を閉じると確認ダイアログを出す（`closeat` のあとに OK を押す）
- この Windows 機は開発専用なので、撮影で変えたアプリの設定（デッキ・アカウント・表示設定）は戻さなくてよい（pooza）
