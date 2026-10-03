# capsicum 開発ガイド

## プロジェクト概要

Flutter ベースの Mastodon / Misskey クライアント。
汎用クライアントとして動作しつつ、[mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy)（通称モロヘイヤ）導入済みサーバーでは拡張機能が利用可能になる。

- **技術スタック**: Flutter / Dart
- **対象プラットフォーム**: Android / iOS / iPad / macOS / Windows / Linux
- **配布**: Google Play / App Store / Mac App Store / Microsoft Store / Linux AppImage（直配）
- **利用者**: サーバーの一般ユーザー

## モロヘイヤ連携

### 基本方針

モロヘイヤはサーバーサイドのインフラであり、ユーザーが存在を意識する必要はない。
capsicum はサーバーが提供する API を検出し、利用可能な機能に応じて UI を出し分ける。

### 透過プロキシとしての動作

モロヘイヤはリバースプロキシとして動作し、capsicum の API リクエスト（`POST /api/v1/statuses` 等）は透過的にモロヘイヤを経由する。投稿時にハンドラーパイプラインが自動的に処理するため、ハンドラーを動かすために特別な投稿経路（webhook 等）を設計する必要はない。モロヘイヤ連携機能を設計する際は、この透過プロキシが前提であることを常に念頭に置くこと。

### 検出

`GET /mulukhiya/api/about` にリクエストし、HTTP 200 + JSON レスポンスが返ればモロヘイヤありと判定する。認証不要でバージョン情報・コントローラ種別も取得できる。
詳細な検出プロトコルや API 仕様の整備依頼はモロヘイヤ側に [capsicum-requirements.md](https://github.com/pooza/mulukhiya-toot-proxy/blob/main/docs/capsicum-requirements.md) として起票済み。

### 拡張機能の主なエンドポイント

モロヘイヤが提供する拡張 API の主なエンドポイント一覧。個別の実装状態は GitHub Issues が正本。

| 機能 | エンドポイント |
|------|--------------|
| サーバー情報表示 | `GET /mulukhiya/api/about` |
| お気に入りタグ | `GET /mulukhiya/api/tagging/favorites` |
| 番組情報 | `GET /mulukhiya/api/program` |
| エピソードブラウザ | `GET /mulukhiya/api/program/works`, `.../episodes` |
| Annict OAuth | `GET /mulukhiya/api/annict/oauth_uri`, `POST /mulukhiya/api/annict/auth` |
| タグ付け | `POST /mulukhiya/api/status/tags` |
| ユーザー設定 | `GET/POST /mulukhiya/api/config` |
| ハンドラー一覧 | `GET /mulukhiya/api/admin/handler/list` |
| メディアカタログ | `GET /mulukhiya/api/media` |

## UI 設計方針 / 対応バージョン方針

⚠ **別ファイルにある → [product-policy.md](product-policy.md)。**用語統一・タグ管理の位置づけ・アクションメニュー・ドロワーのナビゲーション様式・Mastodon / Misskey の機能マッピング・DM の方針・タイムラインの読み込み挙動・公開範囲の考え方・モロヘイヤ連携画面の導線・プッシュ通知・サポート優先順位、および**機能検出（probing）ベースで版番号で分岐しない**という対応バージョン方針はそちら。

⚠⚠ **UI を作る前に読む。**用語と公開範囲の扱いは揺れやすく、揺れると実装が分岐する。

## ブランチ戦略

| ブランチ | 目的 |
|----------|------|
| `main` | リリース済み安定版 |
| `develop` | 開発ブランチ。日常の作業はここで行う |

### リリースフロー

1. `develop` で開発・コミット
2. リリース時に `develop` → `main` へ PR を作成
3. CI（`dart format`・`dart analyze`）が通ることを確認してからマージ
4. `main` でタグを打ちリリース

⚠⚠ **このフローは「develop に乗っているもの ＝ 次に出すもの」が成立するときだけ使える。**成立しない状況が 2 つある（次節）。**フロー記述だけを見て release PR を作らない。**

### develop が次リリース対象でないときの出し方

**まず `git fetch origin` してから `git log origin/main..develop --oneline` で develop の中身を見る。**次マイルストーンの work が乗っていたら、上のフローは使えない。

⚠⚠ **ローカルの `main` を見ない。**`git log main..develop` と書くと**ローカルの `main` ブランチ**を見るが、日常の作業では更新されないので**平気で何リリースも遅れている**。2026-09-17 にこのゲートを初めて実行したとき、ローカル `main` が v1.63 の頃（`d99b3b53`）で止まっており、**121 件**——すでに出荷済みの v1.64 の work を含む——が「develop に乗っている」ように見えた。実際は `origin/main..develop` で **44 件**。⚠ **リモートが正。**このゲートは「フロー記述を鵜呑みにせず差分を見る」ためのものなので、**その差分自体が stale だと目的ごと失われる。**

| 状況 | 判定 |
| --- | --- |
| develop が次リリース対象そのもの | 上のフローでよい |
| **ホットフィックス**（x.y.z）で、develop に次マイルストーンの work が乗っている | 下の手順 |
| **v2.0 開発中の 1.x リリース**（develop が 2.x 線である間はずっと） | 下の手順 |

手順:

1. **`origin/main` から** `fix/NNNN` を切って修正する（⚠ **develop から切らない**・⚠ **ローカル `main` からも切らない**。stale なら 1 つ前のリリースを土台にしてしまう）
2. **`origin/main` から** `release/x.y.z` を切り、必要なコミットだけを載せる
3. release ブランチでビルド・検証する（⚠ **検証する artifact も release ブランチから作る**）
4. `release/x.y.z` → `main` の PR → マージ → タグ → fastlane
5. **`main` を `develop` へ back-merge する**（develop 側が修正を取りこぼさないように）

⚠⚠ **2026-04-27 に実際に事故った。**v1.20.2 のホットフィックスで `fix/385` を develop から切り、この CLAUDE.md の「develop → main」の記述だけを見て release PR を作ろうとした。develop には v1.21 向けコミットが 4 本乗っていたため、**そのままマージしていれば v1.20.2 として出すべきでない内容が main に流れていた**。さらに検証ビルド `1.20.2+49` も develop 起点で作っており、**verified artifact 自体が v1.21 のコードを含んでいて出荷できない状態**だった。⚠ **「branch 操作は安全」と保証する前に、main / develop の差分を実際に見る。**

#### v2.0 開発中は、1.x のリリースが全部この形になる

**v2.0 の実装が develop に乗ると、`develop` → `main` は 1.x に使えなくなる**（大玉 3 本・長期のため、develop は「まだ出せないもの」を数か月抱える）。一方 [roadmap.md](roadmap.md) のとおり **1.x は止められない** —— ユーザー報告・上流追従・Sentry 起点の修正はその間も発生するので、「v2.0 まで 1.x 凍結」は選べない。

したがってこの期間は、**`main` が 1.x 線・`develop` が 2.x 線**になる:

| | 通常 | v2.0 開発中 |
| --- | --- | --- |
| 1.x の修正を切る元 | `develop` | **`main`** |
| 1.x のリリース PR | `develop` → `main` | **`release/x.y.z`** → `main` |
| 取り込みの向き | — | **`main` → `develop`** の一方向 back-merge |
| `develop` → `main` | 毎リリース | **v2.0 を出すとき 1 回だけ** |

⚠ **新しい仕組みではない。**上のホットフィックス手順そのままで、**それが常態になる**というだけ。

⚠⚠ **専用の長寿命ブランチ（`develop-2.0` 等）は作らない。**v2.0 の土台側（[#1087](https://github.com/pooza/capsicum/issues/1087) `timelineProvider` の family 化 / [#1088](https://github.com/pooza/capsicum/issues/1088) family キー / [#1089](https://github.com/pooza/capsicum/issues/1089)・[#1090](https://github.com/pooza/capsicum/issues/1090) streaming の多重化 / [#1095](https://github.com/pooza/capsicum/issues/1095)・[#1096](https://github.com/pooza/capsicum/issues/1096) ProviderScope）は **provider と streaming の根を組み替える**。そして 1.x の不具合修正（ログイン・タイムライン・通知）も、ほぼ必ず同じ層に触る。長寿命ブランチを 2 本持つと、**その面積の乖離を挟んで毎回 cherry-pick する**ことになる。**乖離を抱えるブランチを `develop` 1 本に限る**のが要点。

**切り替えのトリガーは「develop に 1.x として出せない最初のコミットが入った瞬間」。**⚠ どのコミットがそれに当たるかは**系列の境界＝製品判断**（「[マイルストーン運用](#マイルストーン運用)」節）で、技術構造からは導けない。

### Codex レビューの回し方（open PR）

⚠⚠ **採否の判断・返信と 👍 / 👎・取り残しの走査は、ginseng の共通スキル `/ginseng:codex-review` が正本**（#1138・2026-09-21 pooza 判断）。P0〜P3 の扱い、出どころによる切り分け、👎 に反証の実測を添える規律はそちらにある。**ここと同期手順に残すのは capsicum 固有の 5 つだけ** —— この節に巡回の止め方と締めの 1 回、[sync-procedure スキル](../.claude/skills/sync-procedure/SKILL.md) の Codex の節（§6）に API の分かれ方・返信の書かれ方・リリース PR の数え方。

⚠ **プラグインは端末ごとに入れる**（マーケットプレイスは端末単位で、版も端末で決まる）。Mac / miki / Windows のそれぞれで:

```text
/plugin marketplace add pooza/ginseng-style
/plugin install ginseng@ginseng-style
```

⚠ **VS Code 拡張では `/plugin` が使えない**（「isn't available in this environment」）。そのときはターミナルで CLI を使う（中身は同じ操作）:

```sh
claude plugin marketplace add pooza/ginseng-style
claude plugin install ginseng@ginseng-style
```

⚠ **配る側が `plugin.json` の `version` を上げないと届かない**（ginseng-style#104）。ginseng 側を直したのに挙動が変わらないときは、まず版を見る。

⚠ **追加コミットではレビューは発火しない。**`@codex review` を PR コメントに書いた時だけ走る（初回は PR 作成 / ready 化で自動）。**rebase / force-push で SHA が変わったときも打ち直す**。

巡回は次の形で止める（2026-08-23 決定）:

| | 対応 |
| --- | --- |
| 初回レビュー | PR 作成時に自動で走る |
| **P1** | 直して `@codex review` で再依頼 |
| **P2** | **直すだけ。再依頼しない** |
| **マージ直前** | severity を問わず **1 回だけ**再依頼（その PR で最後）。⚠ **初回からの差分が本番コードに触っていなければ省く**（下記） |

⚠ **本番コードに触った回は、締めの 1 回を省かない。**これが無いと「**自分の修正が入れた欠陥を誰も見ない**」経路が残る。#1017 では P2 の修正そのものが退行（`_cancelPendingDraftSave` の移動で自動保存が永久停止）で、次の巡回で見つかった。#1021 では 4 巡目の修正が 5 巡目の穴を作った（宣言側だけ型引数を読み飛ばし、呼び出し側を放置）。

⚠ **省いてよいのは、初回のレビューからの差分が本番コード（`packages/*/lib/` とネイティブ — `ios/` `macos/` `android/` `windows/` `linux/`）に触っていない回だけ**（docs・テスト・CI のみ。2026-09-21 pooza・#1146）。v1.65 では締めの対象が docs 2 件 + テスト修正 1 件で、大半が同じ差分の読み直しになった（Codex も時間も課金される）。⚠ **線は「差分の行数」では引かない** —— 1 行の退行を見逃す。#1017 / #1021 はどちらも本番コードの修正が入れた欠陥だったので、この線なら締めの目的は損なわない。

これで **1 PR あたり最大 2 回**に収まる。青天井にしないのは、#1021 が 6 巡かかった一方で**実コードの違反は初回で出尽くしており**、以降は検査そのものの網の細かさを上げる作業だったため（費用対効果が落ちる）。

各コメントは**返信 + 👍 の両方が揃って「完了」**（片方だけでは同期時に未完了と判定される）。判定手順は [sync-procedure スキル](../.claude/skills/sync-procedure/SKILL.md) の Codex セクションを参照。

### PR マージ後の確認事項

⚠ **マージ後にも指摘が付く。**上の締めの 1 回で拾いきれなかったぶんは、同期手順の Codex セクションで回収する。リリース PR の line comment は別系統なので明示的に数える。

## ディレクトリ構成

⚠ **別ファイルにある → [architecture.md](architecture.md)「リポジトリの構成」。**`.claude/`（スキル・フック・スクリプト）と `docs/` の行き先の表、`packages/` のモノレポ構成はそちら（2026-10-03 に移した・#1184）。

## Issue 管理

- GitHub Issues + Milestones で管理（モロヘイヤと同じ体系）
- 優先度ラベル: P1 〜 P4
- 1 マイルストーンの規模は「大更新の数」で測る（件数ではなく）。詳細は[マイルストーン運用](#マイルストーン運用)節を参照

### 正本ルール

- **Issue のステータス・一覧は GitHub が正本**。CLAUDE.md や MEMORY.md に個別 Issue の一覧・対応済み/未済を複写しない
- リリース計画の確認は `gh issue list --milestone v1.0` 等で GitHub を直接参照する
- CLAUDE.md に書くのは Issue に書けない情報（マイルストーンの方針・運用ルール・設計判断の背景 等）に限定する

### 起票の規約

- 報告元が Fedi の投稿である場合、本文には **投稿の URL リンクのみ** を記載し、報告者の Fedi アカウント名（`@user@server`）は書かない。`@` は GitHub 上でメンションとして解釈され、Fedi と GitHub のユーザー名が一致するとは限らないため、無関係な GitHub ユーザーへの意図しないメンションになる
- 公開投稿ならリンクを辿れば報告者情報に到達できるので、アカウント名を本文に含める必要はない

### マイルストーン運用

マイルストーン完了→次着手の移行時に毎回回す一連の手順（未割り当て Issue のトリアージ・次スコープ確定・ロードマップ調整・capsicum-site 更新・バージョンバンプ）は **`/milestone-transition`** スキル（[SKILL.md](../.claude/skills/milestone-transition/SKILL.md)）。**枠の数・各枠の主題・1.x と 2.x の境界は [roadmap.md](roadmap.md) が正本**（2026-09-04 策定）。以下は判断規約の正本。

⚠ **1.x と 2.x は並走系列で、境界は「時期」でも「技術的な線」でもない。****メジャーに何を載せるかは製品判断（売りの束ね方）**で、pooza が決める。`v2.0` は [#720](https://github.com/pooza/capsicum/issues/720) デッキ UI + [#597](https://github.com/pooza/capsicum/issues/597) 有償リレー + [#884](https://github.com/pooza/capsicum/issues/884) 画像編集レイヤの **3 本を束ねるメジャーリリース**。⚠ **この枠には「大更新 0〜1 件」の目安を当てない**（容量は通常枠の数倍。実績の最大は v1.0 の 46 件に対し直近の平均は 13 件）。技術規模が決めるのは「点リリースで単独配置するか」と「万一入りきらないとき何から逃がすか（＝ #884）」だけ。⚠ **2026-08-17〜 の「外部要因の発生ベース」運用は v1.65 をもって終了**した。

⚠⚠ **容量の特例が当たるのは「メジャーアップグレードの枠」（x.0）だけ**（2026-09-23 pooza）。**x.1 以降は通常の枠**なので、下の「大更新 0〜1 件 + 小粒・中粒 5〜12 件」がそのまま当たる。⚠ **特例を系列の性質（2.x だから大きい）と読み違えないこと** —— 大きいのは **v1.0 / v2.0 のような x.0 の枠**で、理由は**売りを束ねるメジャーだから**。⚠ 2026-09-23 に v2.1 がこの読み違いで過積載（13 件・大更新 2 件）になり、[v2.2](https://github.com/pooza/capsicum/milestone/88) を作って #1074 / #1053 / #1073 を逃がした。⚠ **積載を見るときは、件数より先に「大更新が何件あるか」を数える**（件数だけ見ると 13 件は「わずかな超過」に見える）。⚠ **次に特例が当たるのは 3.0 だが、起こすネタが無いので当分は発生しない見込み**（2026-09-23 pooza）。

- **大更新は独立マイルストーンに単独配置**。UI の構造変更・既存モデルの拡張・複数画面への影響などが絡む「大更新」は、他に同規模以上の項目がないマイルストーンに入れる。並走させると設計検討・実装・動作確認がいずれも中途半端になるため
- **規模の測り方は「大更新の数」が主軸**。1 マイルストーンに入れるのは大更新 0〜1 件 + 小粒・中粒 5〜12 件程度を目安とする。件数は目安であって閾値ではない。リリース前レビュー（5 観点）の followup が膨らんだ場合、上限に縛られて後送りするより同一マイルストーンに取り込んで消化する方が望ましい（直前リリースの設計理解が新鮮なうちに直したいため）。**P1（緊急性あり）に加え、極めて容易な P2/P3 も同一マイルストーンで消化する**（数行の bug fix・コメント書き直し・リネーム・型変更等）。それでも入りきらない場合は、(a) リファクタ系を次マイルストーンに送る、(b) 観測性強化系を分離する、のどちらかで調整する
- **マイルストーン未設定は意図的な場合がある**。実現性検討中・Flutter 側の対応待ち・横断的タスクなどで pooza が意図的に未割り当てにしていることがあるため、「トリアージが必要」等と機械的に指摘しない。同期報告では一覧として淡々と列挙するに留める
- **ユーザー要望の振り分け基準**:
  - 不具合 → 可能なら着手中のマイルストーンに入れる
  - 改善要求（小規模）→ 着手中のマイルストーンに入れる
  - 改善要求（中〜大規模）→ 空いている先のマイルストーンに送る
  進行中のリリースを遅らせないバランスを取りつつ、ユーザーの声には必ず何かしらの形で応える

### 大玉の進め方（棚卸し → 分類 → 設計書 → 起票）

v2.0 に集めたメジャー級の大玉と、その種を見つける棚卸し 3 本（[#991](https://github.com/pooza/capsicum/issues/991) WebUI 差分 / [#992](https://github.com/pooza/capsicum/issues/992) サーバー保存設定 / [#993](https://github.com/pooza/capsicum/issues/993) 未使用 API）の回し方（2026-08-25 合意）。

1. **棚卸しは 1 本ずつ回す。**3 本は母数も手法も違うので同時に走らせない。順序は **#993 → #991 → #992**（#993 が最も機械的で当たりが出やすく、その結果が #991 の見方を決めるため）。**3 本とも完了・親 Issue は 3 本とも close 済み**。続く v2.x のロードマップ（枠の数・各枠の主題・1.x との境界）は [roadmap.md](roadmap.md) に策定済み（2026-09-04）。

   | 親（close 済み） | 完了日 | 成果物 | 続きの Issue |
   | --- | --- | --- | --- |
   | [#993](https://github.com/pooza/capsicum/issues/993) API 基準 | 2026-08-31 | [api-gap-inventory.md](api-gap-inventory.md) | [#1046](https://github.com/pooza/capsicum/issues/1046) 層②③ の残り |
   | [#991](https://github.com/pooza/capsicum/issues/991) WebUI 基準（層① のみ） | 2026-09-03 | [webui-gap-inventory.md](webui-gap-inventory.md) | [#1077](https://github.com/pooza/capsicum/issues/1077) 層② の変種と層③ |
   | [#992](https://github.com/pooza/capsicum/issues/992) サーバー側設定 | 2026-09-03 | [server-settings-gap-inventory.md](server-settings-gap-inventory.md) | [#1078](https://github.com/pooza/capsicum/issues/1078) 未確認 3 点 / [#1079](https://github.com/pooza/capsicum/issues/1079) preferences の決着 |

   ⚠ **親 Issue の close は「宿題の切り出し」とセットにする。**#991 / #992 は完了後も 2 日ほど open のまま残った（2026-09-04 の同期で検出）。宿題を Issue 本文でなく計画書の「未実施」節に置いたため、**行き先が Issue として見えず close の判断がつかなくなっていた**。完了条件が「計画書を残すところまで」の調査 Issue は、**計画書に残った宿題を Issue へ切り出してから close する**。

   ⚠ **#991 が #993 の後でも価値を出した理由を残す。**#993 の分類 A / B / C のどこにも無い項目が 3 件出た。3 件とも `routes/api.rb` にあるので #993 の母数には入っていたが、**capsicum が「付ける」側だけ実装して「見る」側を持っていない**形（お気に入りは付けられるが一覧できない / タグはフォローできるが一覧できない / 引用数は出しているが一覧できない）だった。**エンドポイント単位で数えると片方が緑なので落ちる。画面単位で見ると「一覧が無い」として一発で出る。**棚卸しは母数の取り方を変えると別のものが見える、という実例。

   ⚠ **#992 では「実害の型」が 1 つ増えた。**本文は実害を「誤爆（投稿）」と「見たくないものが見える（読み方）」の 2 種類で定義していたが、実測で出たのは **「見せたくないものが見えている」という第 3 の型**（本人が非表示にしたプロフィールのタブを capsicum が出していた → [#1076](https://github.com/pooza/capsicum/issues/1076)）。**「隠すべきものは隠す」は本来やってなきゃいけない**ので、意思表示の無視ではなく実装漏れとして扱う（2026-09-03 pooza）。**探すときは「サーバーが強制できない設定」から入ると早い** — 強制できるものはサーバーが既に強制しているので、クライアントが落とせる穴はそこにしか無い。

   ⚠ **#993 でいちばん効いた知見: 層を分けて回すこと。**「① 呼んでいないエンドポイント / ② 呼んでいる経路の未使用パラメータ / ③ 受け取っている entity の未読フィールド」の 3 層で見ると、**当たりの性質が層ごとに違った**。層① から出た 4 件は全部 enhancement（機能の欠落）だったのに対し、**層②③ から出た 3 件は全部 bug**（すでに動いている機能の壊れ方）で、しかも 3 件とも**サーバーがエラーを返さない**ため Sentry にもユーザー報告にも出てこないものだった。**層① だけで終えると、この種類は永久に見つからない。**

   ⚠ **層③ をモデルのフィールド一覧で測ると誤診する。**capsicum は一部の値を型付きモデルを経由せず生の `Map<String, dynamic>` から読んでいる。正しい母数の取り方は [api-gap-inventory.md](api-gap-inventory.md) §1「層③ の測り方」にコマンドごと置いた。
2. **分類は 3 分岐にする** — 「1.x で処理」「2.0 以降」に加えて **「拾わない」を必ず明示し、理由を書く**。棚卸しの母数には方針として実装しないもの（英語対応しない / 投稿の更新しない / Fedibird 低優先 / per-server 対応しない 等）が必ず混じるので、**黙って落とすと次の棚卸しで同じものが再浮上する**。
3. **成果物は `docs/` の計画書 1 本にまとめ、Issue 化は分類が確定してから。**先に起票すると、マイルストーン未定のまま滞留する [#905](https://github.com/pooza/capsicum/issues/905) / [#915](https://github.com/pooza/capsicum/issues/915) の形になる。確定後に **1.x 行きだけを稼働中の枠へ、2.0 行きは v2.0 に据え置き**で起票する。
4. **超大玉は設計書を先に書く。**複数 Issue に分解されることが確実なもの（[#720](https://github.com/pooza/capsicum/issues/720) デッキ UI / [#597](https://github.com/pooza/capsicum/issues/597) 有償リレー）は、Issue に割る前に `docs/` へ設計書を置く。⚠ **[#884](https://github.com/pooza/capsicum/issues/884)（画像編集のレイヤ管理）は対象外** — 投稿フォーム内で閉じるので Issue 本文で足り、設計書にすると逆に重くなる。

設計書の型は既存の 6 本（[archive/push-relay-plan.md](archive/push-relay-plan.md) / [archive/desktop-notification-design.md](archive/desktop-notification-design.md) ほか）に倣い、**`## 決定済み事項` と `## 未決事項` を分ける**。未決を明示的に置けるので「全部決まるまで完成しない」状態で止まらない。⚠ **設計書の効用は分解だけではない** — desktop-notification-design では書いた結果 #476 が不要と判明して close できた。**Issue から始めるとこれができない**。

### ソース検査ガードの書き方

capsicum には「ソースを文字列で走査して規約違反を落とす」テストが多い（`test/*_guard_test.dart` 系。ウィジェットツリーを組み立てず静的に見るのは、対象が数十ファイルに散っていて pump の足場を用意するコストに見合わないため）。

⚠⚠ **この形の検査は、判定が壊れても緑になる。**`expect(offenders, isEmpty)` は**何も見ていなくても通る**。v1.61 → v1.62 → v1.63 → v1.64 と **4 リリース続けて「ガードが壊れていても CI が緑」**が出ており（[#1036](https://github.com/pooza/capsicum/issues/1036) / [#1061](https://github.com/pooza/capsicum/issues/1061) / [#1063](https://github.com/pooza/capsicum/issues/1063) / [#1035](https://github.com/pooza/capsicum/issues/1035) の C 群、v1.64 は `exception_scrub_guard_test` が `cause` を見ておらず secret 入りの例外を見逃した件と、carry-over のガードが**アダプターの層だけ見ていなかった**件 [#1113](https://github.com/pooza/capsicum/issues/1113)）、**検査を足す / 直すときは以下を必ずセットで入れる**。

1. **走査が空振りしていないことを別テストで固定する** — 対象ファイル数、既知の対象が列挙に含まれること、置き換え後の形が実在すること。⚠ **「旧形が無い」だけを見ると、「どちらも無い」で緑になる。**
2. **判定ロジックに合成ソースを直接食わせる** — 当たるべき書き方ごとに 1 件、**当ててはいけない形**（コメント・文字列リテラル・真偽判定）にも 1 件。
3. **⚠⚠ 歯があることを、実際に穴を開けて確かめる** — 修正前のファイルを `git show HEAD:<path>` で戻して食わせ、**狙ったテストだけが落ちる**ことを見る。

⚠ **3 を飛ばすと実際に誤読する。**[#1062](https://github.com/pooza/capsicum/issues/1062) のガード初版は「`viewInsets.bottom` の直後が `+` / `,` / `)`」で絞っており、**`final x = ...viewInsets.bottom;` を拾えなかった**（`;` が続くので当たらない）。それは修正対象の実物の形そのもので、**2 の合成テストは自分が想定した書き方しか並べないので通ってしまった**。

#### 判定を書くときの原則

- **列挙をやめ、構造で見る。**「名前の表」は次に増えた名前が黙って通る。⚠ **型が見えないときは「型の代わりになる構造」を探す** — [#1035](https://github.com/pooza/capsicum/issues/1035)-C4 は `AccountKey.host`（非 null）と `User.host`（nullable）を、**「同じ receiver への null ガードが同じファイルにあるか」**で見分けた。
- **コメントと文字列リテラルを落としてから見る**（`test/support/dart_source.dart` の `maskComments`）。⚠ **素朴な `indexOf('//')` は同一行に URL があると行末までを消す。**同じ実装が 3 本へ写されていた（#1035-C5）。
- **集約したものは「委譲していること」まで見る。**正本だけ見ていると、画面が自前実装へ戻っても正本は緑のまま素通りする。⚠ **集約系の再発は「壊れること」ではなく「使わなくなること」として現れる**（[#1083](https://github.com/pooza/capsicum/issues/1083)-A）。

#### 集約するときの注意

⚠ **集約は「レビューで積み上がった振る舞い」を落とす最大の機会。**#1083-A で 4 本を 1 本にしたとき、それぞれに別のレビューで足された守りが 4 種類入っていた（失敗と 0 件の描き分け / 世代カウンタ / 継続判定 / 引っ張って更新）。**集約先の doc に、何を引き継いだかを列挙して残すこと。**

### コミットの分割方針

コミットはなるべく Issue ごとに分ける。レビュー・revert・cherry-pick の粒度を保つため。同じファイルに複数 Issue の変更が混在して分離できない場合のみ、まとめてよい。

### push 前のローカル整形・解析

⚠⚠ **push する前にリポジトリルートで 1 回通す。**`develop` への push でも `analyze.yml` は走るので（v1.48 で drift が溜まった反省から `branches: [main, develop]` になった）赤は必ず見えるが、**push してから踏むと同期のたびに「赤ならその場で直す」手戻りが乗る**（2026-09-01 に #1058 の修正で実際に踏んだ。`786d47cf` → `2561b020`）。

```bash
# format は .gitignore の外の .dart だけにスコープする（build/ を巻き込まない）
git ls-files --cached --others --exclude-standard '*.dart' \
  | xargs -n 40 dart format --output=none --set-exit-if-changed
dart analyze --fatal-infos
```

⚠⚠ **`--others --exclude-standard` を外さない。**`git ls-files '*.dart'` だけだと**追跡対象しか出ない**ので、**まだ `git add` していない新規ファイルが検査をすり抜ける**。⚠ **CI は `dart format .` なので、そこで初めて赤になる**（2026-09-14 に #1136 の新規テストで実際に踏んだ。手元は緑 → push して赤 → `6761fd49` の直後に整形コミットが要った）。`--exclude-standard` が `.gitignore` を尊重するので、`build/` を巻き込む心配はない。⚠ **これは「検査が動いていないのに緑」の一種**で、下の `| tail` と同じ型。

⚠ **`dart format .`（カレント全体）は使わない。**SwiftPM 併存移行（#836）以降、`build/` 配下に他パッケージの SwiftPM checkout（`.dart` を含む）が展開されるため、`.` で流すとバージョン管理外のファイルまで整形対象に拾って drift 判定が誤爆する（v1.51 で誤爆・`3e2783ad`）。

⚠⚠ **`-n 40` を外さない。Windows では 1 本のコマンドに畳むと整形が走らないまま緑に見える**（2026-09-13 実測）。`.dart` は 160 本超あるので cmd の ~8191 文字上限に当たり、`The command line is too long.` を出して**何も整形せずに終わる**。macOS / Linux では上限が高く畳んでも通ってしまうため、**通る端末で書いた形が通らない端末で黙って空振りする**。バッチを割るのは全 OS 共通の書き方にするため。

⚠⚠ **結果を `| tail` 等へ繋がない。**`$?` がパイプ末尾のコマンドのものになり、**整形が失敗していても `0` が返る**（同日に踏んだ）。出力を見たいならファイルへ落として終了コードを先に確かめる:

```bash
git ls-files --cached --others --exclude-standard '*.dart' \
  | xargs -n 40 dart format --output=none --set-exit-if-changed > /tmp/fmt.log 2>&1; echo "FORMAT_EXIT=$?"
dart analyze --fatal-infos > /tmp/analyze.log 2>&1; echo "ANALYZE_EXIT=$?"
```

⚠ これは「[ソース検査ガードの書き方](#ソース検査ガードの書き方)」と同じ形の failure — **検査そのものが動いていないのに緑**。CI で最後は捕まるが、手元で捕まえる意味が消える。

#### docs / skills を触った回は、ガードのテストも通す

⚠⚠ **`dart format` と `dart analyze` は Markdown を見ない。**docs の規約を見ているのは [`docs_convention_guard_test.dart`](../packages/capsicum/test/docs_convention_guard_test.dart) なので、**整形と解析だけで push すると素通りする**（対象は `docs/` 直下・`docs/archive/`・`.claude/skills/`）。

```bash
(cd packages/capsicum && flutter test test/docs_convention_guard_test.dart)
```

🔴 **2026-10-03 に 2 回踏んだ。**`⚠⚠` で始まる見出しを足して push し（`b95ac00b`）、⚠⚠ **CI は赤になるはずが、次の push に追い越されて `cancelled` になり表に出なかった**（追い越されると気付けない）。もう 1 回はこの節自身を足して**本ファイルが 60,000 バイトを超えた**。

⚠ **これは毎コミットの話で、リリース手順の一部ではない**（#1114 の棚卸しで、`store-release-guide.md` §4.0 の中＝リリース時しか読まれない場所に置かれていたのを移した）。

#### 振る舞いを変えた回は、テストを部分実行で済ませない

⚠⚠ **`dart format` と `dart analyze` はテストを走らせない。**CI は `packages/*/` のうち `test/` を持つ 4 パッケージを**全量**流すので、**手元で関係しそうなファイルだけ選んで流すと、期待値を固定した別のテストを取りこぼす**。

```bash
(cd packages/capsicum && flutter test)           # ⚠ 約 4 分・2,300 件
(cd packages/capsicum_core && flutter test)
(cd packages/capsicum_backends && flutter test)
(cd packages/fediverse_objects && flutter test)
```

🔴 **2026-10-03 に踏んだ。**[#1193](https://github.com/pooza/capsicum/issues/1193) で `insertAfter` の重複排除から `SearchTab` を外したとき、`deck_columns_test` ほか 7 本を選んで流して緑を確認し push したが、**`deck_appbar_test.dart` に正反対を固定したテスト**（「検索カラムは 1 本だけ。2 度押しても足さず、そこへ送る」）が残っていて CI が赤になった（`433d73dd`）。

⚠⚠ **これは「歯があることを確かめた」では防げない。**[ソース検査ガードの書き方](#ソース検査ガードの書き方) の 3 点セットは**自分が足したテスト**に歯があるかを見るもので、**既にある別のテストが古い期待値を抱えているか**は見ない。⚠ **仕様を変える変更では、古い期待値の在り処を探すほうが本体**（`grep` で種別名・Issue 番号を当たる / 全量を流す）。

⚠ **選んで流すのは、仕様を変えずに実装だけ直した回に限る。**⚠⚠ **決定済み事項を書き換えた回は必ず全量**（docs を直しているなら、どこかのテストがその決定を固定している）。

### クロスリファレンス

- capsicum → モロヘイヤ: `pooza/mulukhiya-toot-proxy#XXXX`
- モロヘイヤ → capsicum: `pooza/capsicum#XXXX`

## 運営元・課金の方向性

⚠ **別ファイルにある → [product-policy.md](product-policy.md)。**運営主体（個人 / 法人の使い分け）・ストアの登録名義・投げ銭の方向性はそちら。

## 自前サーバー

主な動作確認・連携対象。Mastodon / Misskey フォークを運用しており、モロヘイヤ導入済み。

| 呼称 | ドメイン | 種別 | 備考 |
| --- | --- | --- | --- |
| 美食丼 | `mstdn.b-shock.org` | Mastodon | メインの運用サーバー。#capsicum タグ TL の集約先 |
| デルムリン丼 | `mstdn.delmulin.com` | Mastodon | デフォルトハッシュタグ `#delmulin` |
| キュアスタ！ | `precure.ml` | Mastodon | デフォルトハッシュタグ `#precure_fun` |
| きゅあすきー | `mk.precure.fun` | Misskey | デフォルトハッシュタグ `#precure_fun` |
| ダイスキー | `misskey.delmulin.com` | Misskey | デフォルトハッシュタグ `#delmulin` |

上記はログイン画面のプリセットサーバー一覧にも掲載している。デフォルトハッシュタグは、ローカルタイムラインをハッシュタグタイムラインに置換する独自設計で、これらのサーバーでのみ有効。

## 対応対象外のプラットフォーム

- **WSA (Windows Subsystem for Android)**: WSA 自体が不安定で検証環境として成立しない上、Microsoft が 2025-03 にサポート終了済み。テスターからの検証希望報告があっても Issue 化はせず対応対象外とする

## 関連リポジトリ

| リポジトリ | 内容 |
|-----------|------|
| [mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy) | モロヘイヤ本体。API 仕様の参照元 |
| [mastodon](https://github.com/pooza/mastodon) | Mastodon フォーク（美食丼 / デルムリン丼 / キュアスタ！） |
| [misskey](https://github.com/pooza/misskey) | Misskey フォーク（ダイスキー） |
| [Kaiteki](https://github.com/Kaiteki-Fedi/Kaiteki) | 設計の参考元（アーカイブ済み） |
| [capsicum-relay](https://github.com/pooza/capsicum-relay) | プッシュ通知リレーサーバー（Web Push → APNs / FCM）。Ruby + Sinatra |
| [capsicum-site](https://github.com/pooza/capsicum-site) | プロジェクトサイト（`capsicum.shrieker.net`）。GitHub Pages で配信。プライバシーポリシー・子どもの安全基準等 |

## リリース計画

毎回のリリース手順は **`/store-release`** スキル（[SKILL.md](../.claude/skills/store-release/SKILL.md)）、初回セットアップとストア設定は [store-release-guide.md](store-release-guide.md)。

[GitHub Milestones](https://github.com/pooza/capsicum/milestones) が正本。各マイルストーンの概要・スコープはマイルストーンの description に記載し、CLAUDE.md には複写しない。個別 Issue の一覧・ステータスも同様。

最新リリース: **v1.66.0**（2026-09-21 タグ、build 187、pubspec 1.66.0+187、リリース PR [#1164](https://github.com/pooza/capsicum/pull/1164)、merge `cb2c83ac`）+ **v1.66.1**（2026-09-22 タグ、build 188・**Windows のみ**、リリース PR [#1169](https://github.com/pooza/capsicum/pull/1169)、merge `79c815bc`）。**大更新なし — 返信の宛先を Web UI と同じにする回**（[#1161](https://github.com/pooza/capsicum/issues/1161) が出荷理由）+ v1.65 レビューの送り分。⚠ **この版から動作対象が iOS 15 / macOS 12 以降**（[#1162](https://github.com/pooza/capsicum/issues/1162)・Xcode 27 の下限）。**公開完了（2026-09-22 実測）**: iOS はストアページが 1.66.0 / macOS は lookup が 1.66.0（2026-09-21 公開）/ Windows は Microsoft Store が `1.66.188.0` を返す（displaycatalog）/ Android は production 187（2026-09-22 に Play API で `status=completed` を実測）/ Linux AppImage は [GitHub Release v1.66.0](https://github.com/pooza/capsicum/releases/tag/v1.66.0)（Latest。v1.66.1 は Windows のみのため非 Latest・MSIX のみ添付）。マイルストーン [#85](https://github.com/pooza/capsicum/milestone/85) / [#87](https://github.com/pooza/capsicum/milestone/87)（どちらも 2026-09-22 close）。消化（v1.66 は 9 件）: [#1161](https://github.com/pooza/capsicum/issues/1161) 返信の宛先にメンション全員 / [#1162](https://github.com/pooza/capsicum/issues/1162) 動作対象の引き上げ / [#1144](https://github.com/pooza/capsicum/issues/1144) v1.65 レビューの送り分 / [#1141](https://github.com/pooza/capsicum/issues/1141) Linux キーリング失敗の案内 / [#1120](https://github.com/pooza/capsicum/issues/1120) flutter_secure_storage 更新 / [#1134](https://github.com/pooza/capsicum/issues/1134) dSYM アップロード / [#1146](https://github.com/pooza/capsicum/issues/1146) CI の二重実行 / [#1137](https://github.com/pooza/capsicum/issues/1137) / [#1138](https://github.com/pooza/capsicum/issues/1138) スキル整理。送り分は [#1163](https://github.com/pooza/capsicum/issues/1163) / [#1165](https://github.com/pooza/capsicum/issues/1165)。**relay v1.66.1 は残 0 で完了**（[relay#65](https://github.com/pooza/capsicum-relay/issues/65) WNS 5000B 超過の degrade・`07b1a7e` をステージング / 本番へデプロイ済み・[枠も 2026-09-22 に close](https://github.com/pooza/capsicum-relay/milestone/13)）。

⚠⚠ **v1.66 は v2.0 開発中の 1.x リリースの初回で、2 回とも `origin/main` から `release/x.y.z` を切って出した**（[develop が次リリース対象でないときの出し方](#develop-が次リリース対象でないときの出し方)・#1142）。**back-merge で pubspec が衝突したら develop 側の `2.0.0+…` を残す**（`81aa4c1c` / `d5628802`）。⚠ **v2.0 のビルド番号は 189 以上**（1.x が 188 まで使った）。

⚠ **v1.66.1 は Windows 専用の点リリース**（relay#65）。relay が WNS raw の上限 5000B を超えた通知から暗号化本文を落として `degraded:"1"` で送り、Windows 側は iOS と同じ汎用文面（「capsicum」/「<account> に通知があります」）で出す。**起動中は 8 秒待って、同じアカウント宛を WebSocket 経路が出していなければ出す**（ID が無く dedup できないため・Codex P1 / P2 で詰めた）。実機で「終了中 / 起動中で WebSocket 無し / 8 秒以内に終了」の 3 ケースを本番 relay で確認済み。

過去リリースの詳細ログは [archive/release-log.md](archive/release-log.md) に退避した（正本は [GitHub Releases](https://github.com/pooza/capsicum/releases) / Milestones）。マイルストーン移行時のログトリム手順は [milestone-transition.md](milestone-transition.md) を参照。

### デスクトップ対応

**5 プラットフォームとも出荷済み**（macOS = v1.21 で土台・v1.27 まで / Linux AppImage = v1.24〜 / Windows Microsoft Store = v1.27〜）。⚠ **段階ごとの経緯・動機・配布方針の変遷・v1.24 の Linux 固有差分は [archive/desktop-rollout-settled.md](archive/desktop-rollout-settled.md) へ退避した**（#1184）。各マイルストーンの主題・スコープ・個別 Issue 構成は [GitHub Milestones](https://github.com/pooza/capsicum/milestones) が正本。

設計指針（分岐を最小化するためのルール・**今も効く**）:

- **UI の分岐軸はプラットフォームではなく画面幅**にする。`Platform.isXxx` は UI 層に基本入れない。iPad で画面が広ければデスクトップと同じレイアウトになるべきだし、デスクトップでウィンドウを狭めたらモバイル風になるべき。Responsive design の単一軸に集約する
- **プラットフォーム固有機能は必ず抽象層を経由**させる。`flutter_local_notifications` を直接呼ばず、`BackgroundTaskScheduler` のようなインターフェースを挟む
- **プラットフォーム定数はテーブル化**。ショートカット・メニュー構成などは1箇所にまとめ、プラットフォームごとにテーブルを差し替える
- **条件付きコンパイル（conditional import）は最後の手段**。使う場合も `lib/src/platform/` のような特定ディレクトリに閉じ込める

お知らせ・通知の配送（**触るときは必ず読む**）: desktop 3 OS は「WebSocket streaming → OS ローカル通知」で、native push（macOS APNs / Windows WNS）とは `notification.id` dedup で併存する。⚠ **Linux だけはネイティブ push の経路自体が無い**ため、お知らせは**アプリ起動中しか届かない**（設定画面はトグルの代わりにその旨を説明する）。設計の正本は [archive/desktop-notification-design.md](archive/desktop-notification-design.md)。

配送先を増やすときは **relay の `AnnouncementWorker#deliver` の `case` と capsicum の `deliverableDeviceTypes` が 1 対 1** であること（片方だけ広げると「購読行はあるのに届かない」／「送っても黙って捨てられる」になる）に加え、**payload に載せるフィールドの device_type 差**にも注意する。Windows 宛だけは `announcement_body`（整形済み本文）を足し `announcement_content`（HTML）を落とす — WNS raw の上限 5000B に対して HTML は表示に使われないため。⚠ **この整形本文を全 device_type 共通の payload に足してはいけない**: APNs / FCM は 4KB 上限で、お知らせの payload には degrade で落とせるキーが無く（`ApnsPayload::ENCRYPTED_KEYS` は暗号化 Web Push 由来のキーのみ）、`poll_server` が配送後に `mark_announcement_seen` を打つため **1 通が永久に失われる**（relay PR #43 の Codex P1）。

⚠ **プラグインのデスクトップ対応状況は [desktop-plugin-compatibility.md](desktop-plugin-compatibility.md)、端末のセットアップは [dev-environment-desktop.md](dev-environment-desktop.md)。**

### 運用ルール

運用ルール:

- リリース前レビューは各マイルストーンの Issue をすべて消化した後、リリース直前に毎度実施する。[#27](https://github.com/pooza/capsicum/issues/27) の「セキュリティレビュー」だけでは実害バグを取りこぼすため、以下 5 観点をサブエージェントで並列に走らせる（手順の正本は **`/release-review`** スキル: [SKILL.md](../.claude/skills/release-review/SKILL.md)）:
  - セキュリティ（`/security-review` スキル）
  - API 契約（Mastodon / Misskey / モロヘイヤの REST 正確性、アダプター interface 整合）
  - 並行性・ライフサイクル（async 連鎖、Riverpod provider 寿命、dispose、race）
  - エラー処理・観測性（try/catch カバレッジ、Sentry 計装、secrets scrub、UX）
  - コーディングスタイル・規約整合性（用語統一、ハードコーディング、命名の揺れ、重複ロジック、規約違反）
- **レビュー指摘の起票閾値**: コメント書き直し・既に触っている関数内のリネーム・型変更（`Map<String,bool>` → `Set<String>` 等）・隣接ファイルでの軽微な追従等、起票 + ラベル + マイルストーン + 移動 + close の往復コストが修正コストと拮抗する粒度のものは、issue を起こさず P1 修正の commit に直接含めて消化する。本文に「今は緊急性なし」「必要性が顕在化してから対応」と書きたくなる粒度のものは、起票せずレビュー報告内の note として残す（未来に必要になった時点で起票する）
- **マイルストーンに載らない集約 Issue を作らない**: 「切り出す価値が出たら切り出す」形のアンブレラは、**マイルストーンが付かないので誰も着手せず放置される**（v1.52 / v1.53 の緑まとめ [#905](https://github.com/pooza/capsicum/issues/905) / [#915](https://github.com/pooza/capsicum/issues/915) で 37 項目が滞留し、2026-08-02 に解体）。束ねること自体は可だが、**束ねたら必ずマイルストーンを付け、「その枠で全部やる」チェックリストとして扱う**。行き先の判断基準は [release-review スキル](../.claude/skills/release-review/SKILL.md)を正本とする
- **2 回目レビュー（差分レビュー）**: プラットフォーム追加・大更新独立配置マイルストーンに限り、1 回目の修正 commit に起因する新規問題を拾うため 2 回目を回す。対象は 1 回目以降の差分と新規サーフェスのみ。リリース 1 週間前までに完了させ、直前に出た P1 はホットフィックス前提で次リリースに送ってよい（詳細は [release-review スキル](../.claude/skills/release-review/SKILL.md)）
- ATOK 二重入力（[#54](https://github.com/pooza/capsicum/issues/54)）は Flutter 側の対応待ち。リリースごとにリリースノートの「既知の不具合」に記載し、Flutter 側の関連 issue の動向を確認する。記載時は回避策も併記する: (1) ATOK の「インライン入力」を OFF にする、(2) インライン入力 ON のままでも ATOK の「従来のカーソル位置入力を使用」を ON にすれば回避可（インライン入力を活かせる分こちらが実用的）、(3) 標準キーボードに切り替える
- マイルストーン未設定の Issue は `no:milestone` フィルタで確認する
- **`Windows` / `Linux` ラベルは「その実機でないと進まない」の目印**（再現確認が起点・修正案の選択が実機の挙動次第）。開発のメインは macOS なので、着手できる端末が限られることを一目で分かるようにするためのもの。3 OS 共通のデスクトップ機能に付ける `desktop` とは別で、`desktop` は macOS でも進められる。拾い方は [dev-environment-desktop.md](dev-environment-desktop.md) の「その端末で拾う作業の探し方」
- **`verification-pending` は「実装は済んでいて、動作確認だけが残っている」の目印**（2026-10-01 新設）。⚠ **`reproduction-needed` と逆向き** —— あちらは情報が足りず**着手しない**側、こちらは**出来上がっていて見るだけ**の側。**手が空いたときにまとめて消化する**ための札なので、`gh issue list --label verification-pending` で引けること自体が目的。⚠ **動作確認が済んだら、ラベルを外すのではなく Issue を close する**（close し忘れるとラベルだけが残って数が合わなくなる）。⚠⚠ **`gh issue list --label` は検索インデックス経由で数十秒遅れる** —— 付けた直後に数えるなら `gh api 'repos/pooza/capsicum/issues?labels=verification-pending&state=open'` を使う
  - **付ける側の基準**: UI レイアウト / タップ挙動 / 画面遷移・設定画面の追加のように、**アプリを触れば分かるもの**。⚠ **検証困難なもの（race / fork 依存 / 認証エラーの類別 / 再現条件が薄いもの）には付けない** —— あれらは**動作確認なしで close してよい**側（修正コミットの hash を添えて閉じ、再発は Sentry で観察する）なので、札を付けると**永久に消えないキュー**になる
  - **実機が要るものは端末ラベルと併用する**（例: #1190 は `verification-pending` + `Windows`）。⚠ **`verification-pending` 単独なら「手元の Mac で見られる」**と読めるようにしておく
- Flutter framework 由来の不具合（capsicum 側で根治不能なもの、`flutter` ラベル付き）は [flutter-upstream-watch.md](flutter-upstream-watch.md) で集中管理し、**月初のセッションで手動 chase** して上流の進捗を巡回する。⚠ **クラウドの schedule routine は 2026-08-21 に廃止した**（4 か月連続で発火しても成果コミットが 1 件も残らず、実務はローカル頼みだった）。**資格情報の満了チェックがこの巡回に相乗りしている**点に注意

### 実装しない機能

- 投稿の更新（Mastodon）— SNS にふさわしい機能と判断しないため

## セッション開始時の同期手順

⚠⚠ **手順は Claude Code のスキルにある（#1114）。**docs の側は持たない。

- 会話の最初に「進捗を同期してください」等の指示があった場合 → **`/sync-procedure`**（[.claude/skills/sync-procedure/SKILL.md](../.claude/skills/sync-procedure/SKILL.md)）。⚠ **自動では起動しない**（外へ書く step があるので明示のみ・#1137）。指示されたら Claude は SKILL.md を読んでそのとおり回す
- 作業中にセッションが切れて「続きをやって」と指示された場合 → **`/resume-work`**（[.claude/skills/resume-work/SKILL.md](../.claude/skills/resume-work/SKILL.md)）。⚠ **同期手順は回さない**

⚠ **スキルは「確実に呼ぶ」ための仕組みで、「守らせる」仕組みではない。**守らせたいものは従来どおり `.claude/hooks/` でフック化する。

## ドキュメント表記規約

モロヘイヤ側の規約に合わせる:

- **サーバーの呼称**: 「インスタンス」ではなく「サーバー」を使う
- **ファイル参照**: マークダウンリンクにする
- **見出しはプレーンにする**: ⚠ **見出しの先頭に `⚠` / `⚠⚠` を付けない。**GitHub はアンカーを作るときに記号を落とすため、`### ⚠⚠ develop が…` は `#-develop-…` という**先頭にハイフンが残る**形になり、同じ文書内からのリンクが前例のない綴りになる（2026-09-17 に #1142 で実際に踏んだ）。**強調は本文 1 行目へ移す**。⚠ **機械で見ている**（[`docs_convention_guard_test.dart`](../packages/capsicum/test/docs_convention_guard_test.dart)・#1184。⚠⚠ **フェンス内の `# ⚠ …` は誤検出なので、`grep` の件数で確かめない**）
- **1 ファイルは 1 回で読める大きさに収める**: ⚠⚠ **60,000 バイト以下**（#1184）。Read の上限 25,000 トークンと、docs の **約 2.55 バイト/トークン**という実測から。超えたら**決着した節を [archive/](archive/) へ移す**。⚠ **節番号は振り直さない**（コードのコメントが節を名前で参照している）。判断規約は [doc-maintenance.md](doc-maintenance.md)、検査は上と同じガード

### CLAUDE.md の定期見直し

CLAUDE.md はセッション開始時に全文読み込むため、完了済みの情報や歴史的経緯が蓄積するとノイズとなり、重要な設計方針の認識精度が下がる。マイルストーン数回ごとに CLAUDE.md を見直し、完了済み・陳腐化した情報を削除するか外部参照に集約する。具体的な棚卸し手順（陳腐化改善・memory↔docs の移送・インフラ記述の infra-note 移設・役目を終えた docs のアーカイブ）は **`/doc-maintenance`** スキル（[SKILL.md](../.claude/skills/doc-maintenance/SKILL.md)・不定期／オンデマンド）。⚠ **どこに何を置くかの判断規約は [doc-maintenance.md](doc-maintenance.md)** に残してある（棚卸しのときだけ効くルールではないため）。
