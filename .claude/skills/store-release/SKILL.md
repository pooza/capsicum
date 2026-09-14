---
name: store-release
description: ストアリリースの毎回の手順。relay の残件ゲート → リリース前レビュー → バージョン更新 → ビルドと beta アップロード → 審査提出・製品版昇格 → GitHub Release → Linux (AppImage) / Windows (Store) → 後片づけ。工程ごとの詳細は同じフォルダの補助ファイルにある。⚠ 外向き・取り消せない操作（審査提出・ストア公開）を含む。
---

# ストアリリース手順（毎回）

⚠⚠ **正本はこのフォルダ (#1114)。**[docs/store-release-guide.md](../../../docs/store-release-guide.md) には**初回セットアップ（署名・fastlane・ストア掲載情報）と配布方針**が残っている。**毎回回す手順はこちら。**

## 工程と補助ファイル

⚠⚠ **必要な工程のファイルだけを読む。**全部を 1 ファイルにすると、呼んだ時点で 60 KB が載る。

| 工程 | ファイル | 節番号 |
| --- | --- | --- |
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

⚠ **「push 前のローカル整形・解析」はこの節から出した**（[CLAUDE.md](../../../docs/CLAUDE.md#push-前のローカル整形解析)）。リリース時だけの話ではなく毎コミットの話だったため。

