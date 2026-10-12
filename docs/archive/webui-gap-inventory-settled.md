# 棚卸し: WebUI にあって capsicum に無い機能 — 決着した節の記録

> **アーカイブ（現役運用では参照しない）。**[webui-gap-inventory.md](../webui-gap-inventory.md) の §6（宿題）と §7（起票）の本文を、2026-10-11 に移した。宿題は [#1077](https://github.com/pooza/capsicum/issues/1077) で回し終え（本体の §8）、起票した 6 件は行き先が決まっている。**結論は本体側に残してある。**節番号は本体と同じ。

## 6. 未実施・次回の宿題（2026-09-04 に [#1077](https://github.com/pooza/capsicum/issues/1077) へ切り出し済み）

⚠ **この節は行き先が決まっている。**#991 を close するにあたって、下記のうち引き継ぎ先が未定だった 2 件を **[#1077](https://github.com/pooza/capsicum/issues/1077)（v2.0）** に切り出した。残る 2 件は元から他 Issue が引き取っている。

| 宿題 | 行き先 |
| --- | --- |
| **層③（画面内の表示要素）が丸ごと未実施。**「画面も操作もあるが、出している情報が欠けている」層 | **#1077**。⚠ **#993 の層③（entity の未読フィールド）と母数が重なる**ので、[#1046](https://github.com/pooza/capsicum/issues/1046) と同じ回に回す |
| **層② は「閲覧のみ」パターンしか追っていない。**「作成はできるが編集できない」「一覧はあるが並べ替えられない」等の変種は見ていない | **#1077** |
| **Misskey の設定画面（`/settings/*` 相当）を丸ごと落としている。**落とす基準 5 のとおり意図的だが、⚠ **その中にサーバー側へ保存される値が混ざる** | [#992](https://github.com/pooza/capsicum/issues/992) の母数として引き継ぎ済み（#992 も完了。そこから残った未確認分は [#1078](https://github.com/pooza/capsicum/issues/1078)） |
| **Mastodon の `/public/remote`（リモートのみの連合 TL）**は画面ではなくパラメータの差（capsicum は `local` しか送っていない・`mastodon/client.dart:849`） | 層② の話なので [#1046](https://github.com/pooza/capsicum/issues/1046) 側で扱う |

⚠ **#1077 と #1046 は同じ回に回すが、数え方は 2 通り維持する。**API 基準（#1046）と WebUI 基準（#1077）で母数の取り方が違い、§0 のとおり**片方でしか出ない項目が実際にあった**ため。

## 7. 起票（2026-09-03 完了）

**全 6 件を起票した。**この文書に「まだ起票していないもの」は残っていない。

### A 群 → [v1.63](https://github.com/pooza/capsicum/milestone/77)（pooza の判断）

論点は #993 のときと同じだった。v1.63 は「**#993 の棚卸し成果を消化する専用枠**」として作られており、A 群は #991 の成果なので、枠の趣旨を「棚卸し由来」と読むか「#993 の成果」と読むかで行き先が割れる。

→ **趣旨を「棚卸しの成果」へ広げて v1.63 で消化する**ことにした。決め手は **[#1070](https://github.com/pooza/capsicum/issues/1070) が主役の [#1039](https://github.com/pooza/capsicum/issues/1039) と構造が同一**で、設計を流用できること。milestone description も同日に書き換えた。

⚠ **「内部由来を入れてよい枠ではない」は据え置き。**#1034 / #1035 / #1038 は引き続き入れない。広げたのは「棚卸しの出典」であって「入れてよいものの種類」ではない。

| | Issue | 粒度 |
| --- | --- | --- |
| A-2 | [#1070](https://github.com/pooza/capsicum/issues/1070) フォロー中のハッシュタグの一覧 | 小〜中。⚠ **#1039 とまとめて設計する** |
| A-1 | [#1071](https://github.com/pooza/capsicum/issues/1071) お気に入りの一覧 | 小 |
| A-3 | [#1072](https://github.com/pooza/capsicum/issues/1072) 引用の一覧 | 小 |

### B 群 → [v2.0](https://github.com/pooza/capsicum/milestone/65) 据え置き

| | Issue | 粒度 |
| --- | --- | --- |
| B-1 | [#1073](https://github.com/pooza/capsicum/issues/1073) Misskey の Pages を作成・編集 | 中。⚠ **#1050〜#1053 と同じ族**。束ねて型を決める |
| B-2 | [#1074](https://github.com/pooza/capsicum/issues/1074) Misskey の Play を作成・編集 | 大。⚠ **束に混ぜない・分類 C 行きもありうる** |
| B-3 | [#1075](https://github.com/pooza/capsicum/issues/1075) フィーチャータグ | 小〜中。読む側だけ先行の分割あり |

### 着手順の提案（v1.63 内）

1. **#1039 → #1070**（一覧画面の形・解除の導線を揃える。2 件目が安くなる）
2. #1071（ブックマーク画面の隣に 1 枚）
3. #1072（`_showRebloggedBy` と同じ BottomSheet。⚠ **中身はユーザー一覧でなく投稿一覧**なのでそのまま流用はできない）

### #993 側の訂正

- [api-gap-inventory.md](../api-gap-inventory.md) §1 の「capsicum が使っている `collections` / `in_collections` / `quotes` 系」— **`quotes` エンドポイントは使っていない**（§3 の A-3）。次に api-gap-inventory を触る回で直す

