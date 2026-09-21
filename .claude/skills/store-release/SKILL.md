---
name: store-release
description: ストアリリースの毎回の手順。relay の残件ゲート → リリース前レビュー → バージョン更新 → ビルドと beta アップロード → 審査提出・製品版昇格 → GitHub Release → Linux (AppImage) / Windows (Store) → 後片づけ。工程ごとの詳細は同じフォルダの補助ファイルにある。⚠ 外向き・取り消せない操作（審査提出・ストア公開）を含む。
disable-model-invocation: true
---

# ストアリリース手順（毎回）

⚠⚠ **正本はこのフォルダ (#1114)。**[docs/store-release-guide.md](../../../docs/store-release-guide.md) には**初回セットアップ（署名・fastlane・ストア掲載情報）と配布方針**が残っている。**毎回回す手順はこちら。**

## 工程と補助ファイル

⚠⚠ **必要な工程のファイルだけを読む。**全部を 1 ファイルにすると、呼んだ時点で 60 KB が載る。

| 工程 | ファイル | 節番号 |
| --- | --- | --- |
| リリース前ゲート（どのブランチから出すか） | **この SKILL.md** | §4.-2 |
| リリース前ゲート（relay の残件） | **この SKILL.md** | §4.-1 |
| リリース前レビュー | [release-review](../release-review/SKILL.md) スキル | §4.0 |
| バージョン更新・ビルド・beta アップロード | [build-upload.md](build-upload.md) | §4.1 / §4.2 |
| 審査提出・製品版昇格 | [submit-promote.md](submit-promote.md) | §4.3 |
| GitHub Release のリリースノート | [github-release.md](github-release.md) | §4.4 |
| Linux 配布（AppImage） | [linux.md](linux.md) | §4.5 |
| Windows 配布（Microsoft Store） | [windows.md](windows.md) | §4.6 |
| リリース後の後片づけ | [aftercare.md](aftercare.md) | §4.7 |

⚠ **節番号（§4.2 等）は振り直していない。**本文中に「§4.4 のとおり」という相互参照が 20 箇所以上あり、振り直すと全部を書き換えることになる。**上の表が番号 → ファイルの対応表**。

⚠ 署名鍵・ASC API Key・fastlane の初期設定（§1〜§3）と配布方針（§5）は [docs/store-release-guide.md](../../../docs/store-release-guide.md) 側。**一度だけの作業なので、毎回の手順には持ち込まない。**

### 4.-2 リリース前ゲート: どのブランチから出すか（2026-09-17 追加・必須）

⚠⚠ **他のどの工程よりも先に、`develop` の中身を見る。**

```sh
git fetch origin
git log origin/main..develop --oneline
```

⚠⚠ **`main` ではなく `origin/main` と書く。**ローカルの `main` は日常の作業では更新されないので**平気で何リリースも遅れている**（2026-09-17 にこのゲートを初めて実行したとき、ローカル `main` が v1.63 の頃で止まっており、出荷済みの v1.64 の work を含む 121 件が「develop に乗っている」ように見えた。実際は 44 件）。**このゲートは差分を実際に見るためのものなので、差分自体が stale だと意味が無い。**

**次マイルストーンの work が乗っていたら、`develop` → `main` は使えない。**その場合は `main` から `release/x.y.z` を切り、必要なコミットだけを載せて出す（**検証する artifact も release ブランチから作る**）。判定表と手順の正本は [docs/CLAUDE.md](../../../docs/CLAUDE.md#develop-が次リリース対象でないときの出し方)。

⚠⚠ **v2.0 の実装が develop に乗っている間は、1.x のリリースが毎回この形になる**（`main` が 1.x 線・`develop` が 2.x 線）。**「いつもの develop → main」で進めない。**

⚠ **2026-04-27 の v1.20.2 で実際に事故った。**develop に乗っていた v1.21 の work ごと main へ流しかけ、検証ビルドまで汚染されていた。**フロー記述を鵜呑みにせず、差分を実際に見ること。**

### 4.-1 リリース前ゲート: capsicum-relay の残件（2026-08-22 追加・必須）

**ビルドに入る前に、relay の同名マイルストーンが残 0 であることを確認する。**capsicum 側の Issue だけを見てリリース工程に入らない。

```sh
gh issue list --repo pooza/capsicum-relay --milestone vX.YY --state open
curl -s https://relay.capsicum.shrieker.net/health   # revision が origin/main の HEAD と一致するか
```

残っている場合、**次の 2 つのどちらかを必ず選ぶ**。無言でリリースに進まない。

1. **消化する** — relay 側を実装・デプロイし、`/health` の revision が `origin/main` の HEAD と一致することまで確認する
2. **明示的に繰り下げる** — 残 Issue を**次の同名マイルストーンへ移し**、capsicum 側 description の `## relay` 節を更新する（移送先と理由を書く）。マイルストーンを外して未割り当てに戻さない

⚠ **先送りそのものは構わないが、進捗管理の外で起きてはならない。** 過去に何度か「relay 側を残したまま本体だけリリースした」ことがあり、**気づかないまま置き去りになった**のが問題（deferred なのか forgotten なのかが後から区別できない）。2 を選んだ時点で次の枠に載るので、次リリースで必ず視界に入る。

⚠ **relay に実装が入っているのにデプロイしていない状態でリリースしない。** relay は tag / GitHub Release を持たないため、デプロイし忘れても GitHub 上のどこにも「未出荷」と出ない。判定は `/health` の revision 1 回で済む（relay#37）。

規約の背景と `## relay` 節の書式は `milestone-transition` スキル §3-2、同期時の点検は `sync-procedure` スキルのステップ 5。

### 4.0 リリース前レビュー

⚠⚠ **本文はスキルへ移した（#1114）→ [.claude/skills/release-review/SKILL.md](../release-review/SKILL.md)（`/release-review`）。**5 観点の並列レビュー・赤黄緑の分類と緑の送り先・2 回目を回す条件はそちらが正本。

**Issue を消化しきったらビルドに入る前に回す。**⚠ ここを飛ばしてビルドに入らない。

#### ⚠⚠ 5 観点を走らせる前に、リリース PR を ready にする（2026-09-17 追加）

**`/release-review` を起動するのと同じタイミングで、develop → main のドラフト PR を ready にする。**

```sh
gh pr ready <PR番号> --repo pooza/capsicum
gh pr comment <PR番号> --repo pooza/capsicum --body "@codex review"
```

⚠ **ready 化だけでは走らないことがある**ので、`@codex review` を明示的に打つ（2026-09-17 に実際に発火しなかった）。

**なぜここか。**[release-review スキル](../release-review/SKILL.md)は「Codex は PR ready 時に走るので**併走させ**、重複しない指摘だけを拾う」と書いているが、**ready にする step がどこにも無かった**ため、実際には §4.4 まで ready されず**併走が成立していなかった**。v1.65 では Codex の指摘（P1 1 件 + P2 1 件）と CI のテスト失敗が、**Apple 2 つを審査提出し Android を製品版へ昇格したあとに**届いた。⚠ **その時点では取り込めない**（バイナリは既に Apple の審査に入っている）。

ここで ready にすると:

- Codex の指摘と 5 観点の指摘を**同じ修正コミット群で消化できる**
- **レビュー済みのコードでビルドできる**（今の順序だと、ビルドしたあとに指摘が来る）
- PR 粒度の CI（`pubspec.lock` churn ガード等）も早く回る

⚠ **ready 化すると以降の push ごとに PR の CI が走る**（draft ガード #987 の意図どおり）。これは織り込みずみのコスト。

⚠ **マージ直前の「締めの 1 回」は別途必要**（`docs/CLAUDE.md`「Codex レビューの回し方」）。ここで打つのは初回。

⚠ **「push 前のローカル整形・解析」はこの節から出した**（[CLAUDE.md](../../../docs/CLAUDE.md#push-前のローカル整形解析)）。リリース時だけの話ではなく毎コミットの話だったため。

