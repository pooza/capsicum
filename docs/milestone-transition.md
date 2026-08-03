# マイルストーン移行手順

直近マイルストーンが**全プラットフォーム公開完了**した後、次のマイルストーンに着手するまでの間に毎回行う一連の整備手順。[sync-procedure.md](sync-procedure.md)（セッション開始時の同期）と [store-release-guide.md](store-release-guide.md)（ストアリリース）の間を埋める。

## 実行タイミング

- 直近マイルストーンの残 Issue が 0、かつ全 5 プラットフォーム（Android / iOS / macOS / Windows / Linux）で公開完了を確認したとき。
- 判定は [sync-procedure.md](sync-procedure.md) の同期結果を流用してよい（リリースタグ・Play/ASC API・GitHub Release）。公開未完了なら着手準備は早いので、この手順には入らない。

## 手順

判断規約の正本は [CLAUDE.md の「マイルストーン運用」](CLAUDE.md#マイルストーン運用)。ここでは「移行時に何を・どの順で回すか」を定める。

### 1. 完了確認

- 直近マイルストーンを close 済みにする（残 Issue 0 が前提）。
- 主役 Issue が close 済みで、リリースノート / リリースログに反映されていることを確認。
- **[capsicum-relay](https://github.com/pooza/capsicum-relay) の同名マイルストーンも残 0 であることを確認する**（下記「関連リポジトリの同名マイルストーン」）。

  ```sh
  gh issue list --repo pooza/capsicum-relay --milestone vX.YY --state open
  ```

### 2. マイルストーンなし Issue のトリアージ・割り当て

- `gh issue list --state open --limit 100` の全 open Issue から、マイルストーン未割り当てを抽出する。
- **先に「割り当てを促さない」グループを分離する**（機械的に割り当て提案しない）:
  - `on-hold` ラベル = 経過観察。割り当てない。
  - `reproduction-needed` / 再現待ち = 割り当てない。
  - `flutter` ラベル = Flutter 上流待ち。監視対象。本文だけでなくコメント履歴も読む。
  - Sentry 後継観測 Issue = 件数推移で再判断。割り当てない。
  - 実現性検討中・横断的タスクで pooza が意図的に未割り当てにしているもの。
- 残りを振り分ける:
  - 不具合 → 可能なら着手中（＝次の）マイルストーンへ。
  - 改善要求（小規模）→ 着手中のマイルストーンへ。
  - 改善要求（中〜大規模）→ 空いている先のマイルストーンへ。
  - **計画済みの後続**は未割り当てで止めず、具体的な先のマイルストーン（無ければ新規作成）に置く。未割り当ては on-hold に見えるため。
- **過去のスコープアウト / 先送り履歴を尊重する**。テーマ一致だけで、一度外した Issue を稼働中マイルストーンに戻さない。
- ユーザー要望由来の Issue は遠い集約枠に送らず近接維持。内部由来（parity / refactor）と扱いを分ける。

### 3. 次マイルストーンのスコープ確定

- 規模は「大更新の数」で測る。**大更新 0〜1 件 + 小粒・中粒 5〜12 件**を目安に組む。
- 大更新は独立マイルストーンに単独配置（他に同規模以上を並走させない）。
- GitHub Milestones が正本。description に (a) 大更新の単独配置か否か、(b) 主な含有 Issue、(c) 並走条件・着手律速 を記載する（CLAUDE.md には複写しない）。
  ```
  gh api -X PATCH repos/pooza/capsicum/milestones/{number} -f description="..."
  ```

### 3-2. 関連リポジトリの同名マイルストーン（capsicum-relay）

capsicum-relay は独自のリリースサイクル（tag / GitHub Release）を持たないため、**マイルストーンが無いと着手の理由が発生せず、先回り・構造改善系の Issue が永久に滞留する**。実際、close 済みは全て即日〜2 日（壊れたら直す系）で、残っているのは全部が未着手の構造改善だった（2026-08-03 に 7 件を確認）。

これを防ぐため、**capsicum のマイルストーンと同名の枠を relay 側にも作り、その回に消化する分を入れる**。「いつやるか」＝マイルストーン、「何の系統か」＝ラベル（`観測` / `配信` / `基盤`）で分ける。

- 次マイルストーンのスコープを決めるとき、**relay の未割り当て Issue も同時に見る**。

  ```sh
  gh issue list --repo pooza/capsicum-relay --state open --json number,title,milestone,labels
  ```

- 消化する分があれば relay 側に同名マイルストーンを作って割り当てる。**capsicum 側の description にも 1 行書く**（どちらから見ても対応が分かるように）。

  ```sh
  gh api -X POST repos/pooza/capsicum-relay/milestones -f title="vX.YY" -f description="..."
  ```

- **その回に relay を触らないなら枠を作らない。**空枠を量産しない（0 件の枠は「やらない」と区別が付かず、v1.20.1 が 3 ヶ月半放置された）。
- 枠を作らないと決めた回は、capsicum 側マイルストーンの description に「relay: なし」と明記する。**判断したことが読み取れる状態にする**のが目的で、無言の未割り当てにしない。
- relay 側の作業範囲は commit + flauros デプロイまで（メモリ `feedback_capsicum_relay_deploy_delegation` が正本）。ブランチは原則 main 直（`feedback_capsicum_relay_branching`）。

### 4. 直近ロードマップの調整

- 過積載マイルストーンは分割・繰り下げで解消する（大更新の分離が基本。要望由来は据え置き）。
- リリース前レビューの followup は、上限に縛られて後送りするより直近マイルストーンで消化する方が望ましい（設計理解が新鮮なうち）。
- 調整の論点・経緯は memory の `project_roadmap_*` に残す（GitHub Milestone の description が正本、memory は判断経緯）。

### 5. capsicum-site の更新

- リポジトリは `~/repos/capsicum-site`。master 直 push でよい（情報の鮮度優先）。
- **実装済み機能**: 直近リリースで出荷した機能をサイトの機能紹介に反映する。
- **公開ロードマップ**: themed / 大更新は先に掲載してよい。**集約枠（内容が流動的なもの）はリリースが近づいてから載せる**（先に載せると陳腐化する）。

### 6. バージョンバンプ

- スコープ確定直後に `develop` で `packages/capsicum/pubspec.yaml` の version を次の `x.y.0` に上げる（後回しだと開発中に旧バージョン表示で混乱する）。
- **build 番号（`+NNN`）は既に使用済みの最大値の次以降**にする。spike ブランチ等で build を進めていることがあるため、`git log` / Play・ASC で使用済み番号を確認してから採番する。
  ```
  # 例: develop が 1.42.1+140、spike で +145 まで進んでいる → 1.43.0+146
  ```

### 7. リリースログのトリム

CLAUDE.md は毎セッション全読されるため、リリースログを肥大させない。**CLAUDE.md の「リリース計画」節には「最新リリース」1 本だけを詳細で残し、それ以前は [archive/release-log.md](archive/release-log.md) へ退避する**。

- 新しいリリースを出すたびに、CLAUDE.md の旧「最新リリース」段落を `docs/archive/release-log.md` の先頭（`---` の直後）へ移し、新リリースを「最新リリース: **vX.Y.Z**（…）」として CLAUDE.md に書き直す。CLAUDE.md 側にはアーカイブへのポインタ 1 行だけを残す。
- リリース段落に埋もれた**運用上の罠**（build 番号ルール・msix_version・iOS 提出順・16KB 等）は、archive へ移す前に [tech-notes.md](tech-notes.md) / [store-release-guide.md](store-release-guide.md) の該当箇所へ反映する（archive は経緯ログ、再発防止の正本は tech-notes / guide 側）。
- **ホットフィックス（x.y.z）でも同様にトリムする**（milestone transition を伴わないが、リリース＝ログ追加のたびに実施）。
- 詳細なリリースノート・消化 Issue・公開状況の**正本は GitHub Releases / Milestones**。archive はあくまで CLAUDE.md から退避した作業ログであり、網羅的な履歴インデックスを目指さない。

## 完了後

- メモリの `project_v1XX_progress`（**次**マイルストーン）を新規作成 or 更新し、スコープと着手状況を記録する。
- **出荷完了した版の `project_v1XX_progress` は削除する**。進捗メモリは**稼働中のマイルストーン 1 本だけ**に保つ（2026-07-17 方針化）。出荷済みの内容は GitHub Releases / Milestones（正本）と step 7 で退避した [archive/release-log.md](archive/release-log.md) に既にあり、メモリに残すと 4 重管理になってメモリ索引が肥大する。削除前に、GitHub からは読めない事実（資格情報の満了日・環境の癖・再発する罠）が埋もれていないか確認し、あれば step 7 と同じ要領で docs か `reference_*` メモリへ先に昇格させる。
- 未割り当てのまま残した Issue は、同期報告で一覧として淡々と列挙する（割り当てを促す文言は不要）。
