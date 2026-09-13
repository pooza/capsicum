### 4.7 リリース後の後片づけ・次マイルストーン準備（毎リリース後）

公開が一巡したら、次のマイルストーンに入る前に以下を一括で行う。**capsicum-site の更新までが 1 セット**。多くは他手順（[sync-procedure.md](../sync-procedure/SKILL.md) / §4.4 / [CLAUDE.md](../../../docs/CLAUDE.md)「マイルストーン運用」）への参照で、ここはチェックリストとして機能させる。リリース後の最初の同期セッションで sync-procedure と合わせて回すことが多い。

#### A. 公開の完走確認

- 全プラットフォームの公開状況を**実測**で確認する（§4.4 の lookup / ASC API のプラットフォーム別 `appStoreState` + Play production track の versionCode + GitHub Release が Latest か）。推測しない。
- iOS が審査中（`IN_REVIEW`）でも、通例どおり短期通過する routine のため「完走扱い」にしてよい（pooza 判断）。残りが iOS 審査のみなら待たずに次へ進む。

#### B. リリース記録の更新

- [CLAUDE.md](../../../docs/CLAUDE.md)「リリース計画」の「最新リリース」に新バージョンを追記し、前版をリリースログへ降格する。
- メモリ `project_v1xx_progress` を出荷状況（実測）で更新する。

#### C. capsicum-site の更新（`~/repos/capsicum-site`・master 直 push 可）

- `index.md`「最新リリース」を新版に差し替え、概要（看板・主な変更）を 1 段落で書く。
- `index.md`「主な機能」に、今回追加した目玉機能を反映する。
- `index.md` /  `desktop/index.md` のロードマップから消化済みを外し、後続マイルストーンを繰り上げる（GitHub リンクは milestone 番号が固定なので付け替えに注意）。
- 新機能・デスクトップ等の**説明文を見直す**。themed / 大更新は先に掲載してよいが、集約枠（内容が流動的な version 集約枠）はリリースが近づいてから載せる。
- ※ここで更新するのは**サイトの**説明文。**ストア掲載文は提出時しか変えられないため §4.3 で済ませている**（混同しない）。

#### D. 次マイルストーンの整備

- on-hold 解除・新規 issue を適切なマイルストーンへ振り分ける（振り分け基準・据え置き/先送り履歴の尊重は CLAUDE.md「マイルストーン運用」と MEMORY に従う）。
- 直近マイルストーンの**過積載点検**（中粒 5〜12 件 + 大更新 0〜1 件が目安）。膨れていれば、一塊のテーマ束を独立配置のマイルストーンへ分離し、以降のマイルストーンを 1 つずつ繰り下げる（連番なので、退避用の一時タイトルを経由してタイトル衝突を避けつつ tail をずらす）。
- マイルストーン description の版番号 cross-ref（「後続 v1.xx」等）を再編後の並びに整合させる。
- 次マイルストーン着手時に pubspec の version を先にバンプする（後回しにすると開発中ずっと旧版表示で混乱するため）。

#### E. 環境・互換の確認

- Mastodon / Misskey の現行バージョンを fork pull で確認する（sync-procedure §8）。メジャー / マイナーが上がっていれば API トリアージ（[mastodon-capsicum-api-watch.md](../../../docs/mastodon-capsicum-api-watch.md) / [misskey-capsicum-api-watch.md](../../../docs/misskey-capsicum-api-watch.md)）の要否を判断する。

