# 大玉の進め方（棚卸し → 分類 → 設計書 → 起票）

⚠ **[CLAUDE.md](CLAUDE.md) から移したもの**（#1139・2026-10-03）。⚠⚠ **次に大玉を回すときは先に読む。**

## なぜスキルではなく docs に置いたか

[#1139](https://github.com/pooza/capsicum/issues/1139) の件名は「スキルへ移す」だったが、**docs の 1 本にした**。理由は #1139 の本文が挙げていた懸念がそのまま当たるため。

⚠⚠ **この手順は記録側を読まないと始まらない。**棚卸しの母数・層の取り方・「当たりではなかった」記録は [api-gap-inventory.md](api-gap-inventory.md) / [webui-gap-inventory.md](webui-gap-inventory.md) / [server-settings-gap-inventory.md](server-settings-gap-inventory.md) にあり、設計書の型は [deck-ui-plan.md](deck-ui-plan.md) / [paid-relay-plan.md](paid-relay-plan.md) が実例。**スキルにすると SKILL.md を読んでから docs を読むことになり、読む量は減らず往復だけ増える** —— [#1114](https://github.com/pooza/capsicum/issues/1114) で `*-api-watch.md` をスキルにしないと決めたのと同じ理由。

⚠ **移した動機はスキル化ではなく CLAUDE.md の大きさだった**（2026-10-03・#1184）。CLAUDE.md が 56,165B（閾値 60,000 まで 3,835B）まで戻り、この節が 6,847B ＝ 全体の 12% を占めていた。**セッション開始時に全文読む CLAUDE.md から、必要な回だけ読むものを降ろす**のが目的。

⚠ **スキルにする案は捨てていない。**⚠⚠ ただし**実際に次の大玉を回してから判断する**（#1139 の「回してから判断するのが安い」はそのまま有効）。回した結果「手順だけで足りる」と分かったら、そのときスキルへ移す。

---

## 回し方

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

