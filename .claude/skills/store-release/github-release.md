### 4.4 GitHub Release のリリースノート

#### 前段: リリース PR のマージとタグ（§4.3 の後・2026-10-29 追加）

⚠⚠ **Apple 2 つの審査提出と Android の製品版昇格（§4.3）が済んでから**、リリース PR をマージしてタグを打つ。タグで Linux（§4.5）と Windows（§4.6）の CI が走り、draft の Release ができる。⚠ 以前はこの段がどこにも書かれておらず、[docs/CLAUDE.md](../../../docs/CLAUDE.md) の「リリースフロー」の 1 行と、メモリ・前回の実績から組み立てていた。

1. リリース PR（`develop` → `main`）の CI が緑であることを見て、**マージコミットで**マージする（`gh pr merge <番号> --repo pooza/capsicum --merge`）
2. `git fetch origin` してから、**`origin/main` のマージコミットに注釈付きのタグ**を打って push する（`git tag -a vX.Y.Z <マージコミット> -F <本文のファイル>` → `git push origin vX.Y.Z`）。⚠ ローカルの `main` は古いので使わない
3. タグのメッセージは**リリースノートの本文と同じもの**（下の体裁）。GitHub Release の本文にも同じものを入れる（メモリ `feedback_release_pr_body`。前例: `v2.6.0`）
4. CI が作った **draft の Release に本文を入れる**。⚠⚠ **Release を先に作らない**（§4.5 の注意。CI が draft を外して公開してしまう）。⚠ **公開するのは pooza**（公開すると release_bot が Fedi へ告知する）。⚠⚠ **公開はストアへの審査提出のお知らせとして、提出の時点で行う**（2026-10-29 pooza）。ストアで公開されるのを待たない —— 「公開を見てから」と勧めない

⚠ リリース PR の本文は、リリースノートと同じ内容なら空でよい（同メモリ）。§4.0-2 の「スクリーンショットは見送り」の 1 行は本文に残す。

#### 体裁は直前リリースを踏襲する

**リリースノートの体裁は「直前のリリースのリリースノート」が正本**。毎回同じ読み口にするのが目的なので、書き始める前に `gh release view v<直前>` で構成を確認してから起こす（v1.57 の初稿で体裁を外し、pooza から「いつものものに」と差し戻された）。

- 見出しは `## 新機能・改善` / `## 不具合修正` / `## その他` / `## Linux (AppImage)` / `## 既知の不具合（bug ラベル open Issue）`
- 各項目は **Issue タイトルの転記ではなく、太字の要点 + 「何がどう変わるか」の説明**で書く。Issue 番号は末尾に添える
- **`## 入手方法` のようなプラットフォーム列挙の節は作らない。** ストアバッジ等は公式サイト側の仕事で、リリースノートで列挙すると特定プラットフォームだけ強調する形になりやすい（メモリ `feedback_windows_store_no_special_emphasis` / `feedback_no_msix_sideload_in_release_notes`）。Linux セクションだけは §4.5 のとおり必ず入れる（ストア展開が無く、このワンライナーが最優先の導線のため）

#### 既知の不具合

「既知の不具合」セクションを作る場合は、ハードコードせず **bug ラベルが付いた open Issue を列挙** する。固定の文言は実態とズレるため、Issue が正本となるように書く。

```bash
gh issue list --label bug --state open
```

この結果をもとにリリースノートの「既知の不具合」を構築する。ただし **列挙するのはユーザーから見える不具合だけ**で、観測目的の Issue（Sentry 後継観測など）と再現待ちの Issue は落とす。

⚠⚠ **直前のリリースノートの一覧を引き写さない。毎回 `gh issue list` の結果から組み直す。**「体裁は直前を踏襲する」は見出しと書き方の話で、**一覧の中身は踏襲の対象ではない**。v2.1.0 で #94（テキスト選択メニューが英語表示）と #54（ATOK の二重入力・回避策つき）が理由なく抜け、v2.2.0 の初稿が「前回と同じ」にしてその抜けを引き継いだ（2026-10-12 に pooza が件数の少なさで気付いた）。

⚠ **落とすときは、上の 2 つの理由（観測目的・再現待ち）のどちらかを言えること。**`on-hold` は落とす理由にならない（直す予定が立っていないだけで、利用者は踏む）。⚠ 回避策のある不具合は、回避策も一緒に載せる（#54）。

#### 公開状況の外形確認（App Store lookup API）

iOS / macOS の「審査提出済み」と「公開済み」の差は、Apple の iTunes Search API (lookup) で認証なしに確認できる。`currentVersionReleaseDate` が最新版のストア反映日時。

```bash
# iOS / iPadOS（bundleId は Universal Purchase 共通）
curl -s -A "Mozilla/5.0" "https://itunes.apple.com/lookup?bundleId=jp.co.b-shock.capsicum&country=jp" \
  | jq -r '.results[] | "\(.kind) \(.version) \(.currentVersionReleaseDate)"'

# macOS（Mac App Store、entity=macSoftware）
curl -s -A "Mozilla/5.0" "https://itunes.apple.com/lookup?bundleId=jp.co.b-shock.capsicum&country=jp&entity=macSoftware" \
  | jq -r '.results[] | "\(.kind) \(.version) \(.currentVersionReleaseDate)"'
```

注目フィールド: `version`（最新公開バージョン）/ `currentVersionReleaseDate`（ストア反映時刻 UTC）/ `releaseDate`（初公開日）/ `trackViewUrl`。

注意:

- User-Agent がないと空応答になることがあるため `-A "Mozilla/5.0"` を付ける。`country=us` 等で他ストアも確認できる
- **片方ストアが長期停滞中だと lookup の `version` が実態と乖離する**。Universal Purchase の `trackId` 共有の都合で、iOS と macOS のどちらか古い方の公開バージョンが優先表示されることがある（例: iOS が新版公開済みでも macOS が審査停滞中だと両 storefront とも古い方を返し続ける）。lookup は公開済みアプリの現行版しか返さないため、**審査中（`WAITING_FOR_REVIEW` / `IN_REVIEW`）かどうかや iOS / macOS の個別ステータスは原理的に分からない**

#### 審査ステータスのプラットフォーム別確認（App Store Connect API、推奨）

iOS と macOS の審査状態を**別々に正確に**取得するには App Store Connect API を使う（lookup では Universal Purchase の同一レコードを拾うため不可）。`appStoreVersions` を `platform`（`IOS` / `MAC_OS`）でフィルタすると各版に `appStoreState`（`READY_FOR_SALE` = 公開済み / `WAITING_FOR_REVIEW` = 審査待ち / `IN_REVIEW` = 審査中 / `PENDING_DEVELOPER_RELEASE` 等）が付く。**今後 iOS / macOS の公開状況確認はこの方法を第一とする**（lookup は補助）。

⚠⚠ **スクリプトは [`.claude/scripts/asc-status.rb`](../../scripts/asc-status.rb)。**リポジトリ root から相対パスで呼ぶ（`permissions.allow` の `Bash(.claude/scripts/asc-status.rb *)` に当てるため）。

```sh
.claude/scripts/asc-status.rb versions   # iOS / macOS の審査状態
.claude/scripts/asc-status.rb products   # 課金商品の状態と日本の価格
.claude/scripts/asc-status.rb            # 両方
```

認証は fastlane と同じ ASC API Key（`~/.config/capsicum/AuthKey_<KEY_ID>.p8`）を流用し、ES256 JWT を生成して叩く（Ruby の `jwt` gem 利用）。⚠ `<KEY_ID>` は**鍵のファイル名から**、`<ISSUER_ID>` は **`ios/fastlane/Fastfile` から**取るので、通常は環境変数を置かなくてよい（`ASC_KEY_ID` / `ASC_ISSUER_ID` で上書きできる）。⚠⚠ **スクリプトに識別子を書き写さない** —— 複写すると、片方だけ差し替えられたときに気付けない。

⚠⚠ **以前はここに `ruby -e` のワンライナーが載っていたが、`deny-interpreter-inline` のフックが拒否するため実行できなくなっていた**（`docs/dev-environment.md`「コマンドの書き方」）。⚠ **インラインへ戻さない。**

#### 課金商品（サブスク・消耗型）の状態確認

⚠ **アプリの版が `READY_FOR_SALE` でも、課金商品は別に審査される。**`asc-status.rb products` で `state` を見る。

| `state` | 意味 |
| --- | --- |
| `MISSING_METADATA` | 必須項目が埋まっていない（審査に出せない） |
| `READY_TO_SUBMIT` | ⚠ **埋まったが審査に出していない。**まだ買えない |
| `WAITING_FOR_REVIEW` / `IN_REVIEW` | 審査中 |
| `APPROVED` | 承認済み（⚠ サブスクは価格の開始日も要る） |

⚠⚠ **新規 IAP は単独で審査提出しない**（§4.2 の審査ノート）。アプリのバージョン提出に紐付けて同時に出す。

#### Microsoft Store の公開確認（displaycatalog、認証不要）

Windows は Partner Center から pooza が手動 publish するため、Claude 側からは**認定が通って実際に差し替わったか**だけを外形で見る。ストアの公開カタログ API が認証なしで現行パッケージを返す（Store ID `9NP2GR7M2W6P` は[ストアページ](https://apps.microsoft.com/detail/9np2gr7m2w6p)の URL と同じ公開値）。

```sh
curl -s "https://displaycatalog.mp.microsoft.com/v7.0/products/9NP2GR7M2W6P?languages=ja-jp&market=JP" \
  | jq -r '.Product.DisplaySkuAvailabilities[0].Sku.Properties.Packages[0].PackageFullName'
```

`9AFBB08E.capsicum_<version>.<build>.0_x64__8ekzzj58251a2` が返る。**提出直後はまだ前バージョンを返す**ので、ここが新しい版に変わって初めて公開完了と判定する（例: v1.58 なら `1.58.171.0`）。

#### Google Play production トラックの確認

`fastlane release` が意図したビルドを昇格したかは Play API で実測する（§4.2 の versionCode 衝突事故対策）。ASC と同じく service-account JWT を作り、`edits` を開いて `tracks/production` を読む。認証は `~/.config/capsicum/google-play-service-account.json`。

⚠⚠ **スクリプトは [`.claude/scripts/play-status.rb`](../../scripts/play-status.rb)。**リポジトリ root から相対パスで呼ぶ（`permissions.allow` に当てるため）。

```sh
.claude/scripts/play-status.rb               # production / alpha / internal
.claude/scripts/play-status.rb production    # トラックを指定
```

⚠ **以前はここに `ruby -e` のワンライナーが載っていたが、`deny-interpreter-inline` のフックが拒否するため実行できなかった**（2026-10-08 の v2.0.1 のリリースで踏んだ・App Store 側の `asc-status.rb` と同じ経緯）。⚠ **インラインへ戻さない。**

`status=completed` かつ `versionCodes` がそのリリースの build 番号なら製品版公開済み。⚠ **`edits` を開くだけなら Play 側に副作用は無い**（commit しなければ破棄される）。

> ⚠️ **darwin では `ruby` を叩く前に rbenv shims を PATH 先頭に置く**（非対話 shell だと macOS 同梱 2.6 や壊れた MacPorts に落ち、`jwt` gem が見つからず「確認できない」と誤認する）。`export PATH="$HOME/.rbenv/shims:$PATH"` してから `ruby -v` が 3.x であることを確かめる。

