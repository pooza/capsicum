# メジャーを develop に仕込んでいる間の、現行系列のリリース（v2.0 開発中の記録）

> **アーカイブ（現役運用では参照しない）。**[CLAUDE.md](../CLAUDE.md)「develop が次リリース対象でないときの出し方」から移した（2026-10-11）。この期間は 2026-10-08 の v2.0.0 で終わっている。**次にメジャーを develop へ仕込むときの手引き**として残す。結論と手順は CLAUDE.md 側にある。

## v2.0 開発中は、1.x のリリースが全部この形になる

この形で出したのは v1.66.0 / v1.66.1 の 2 回。

**v2.0 の実装が develop に乗ると、`develop` → `main` は 1.x に使えなくなる**（大玉 3 本・長期のため、develop は「まだ出せないもの」を数か月抱える）。一方 [roadmap.md](../roadmap.md) のとおり **1.x は止められない** —— ユーザー報告・上流追従・Sentry 起点の修正はその間も発生するので、「v2.0 まで 1.x 凍結」は選べない。

したがってこの期間は、**`main` が 1.x 線・`develop` が 2.x 線**になる:

| | 通常 | v2.0 開発中 |
| --- | --- | --- |
| 1.x の修正を切る元 | `develop` | **`main`** |
| 1.x のリリース PR | `develop` → `main` | **`release/x.y.z`** → `main` |
| 取り込みの向き | — | **`main` → `develop`** の一方向 back-merge |
| `develop` → `main` | 毎リリース | **v2.0 を出すとき 1 回だけ** |

⚠ **新しい仕組みではない。**ホットフィックスの手順そのままで、**それが常態になる**というだけ。

⚠⚠ **専用の長寿命ブランチ（`develop-2.0` 等）は作らない。**v2.0 の土台側（[#1087](https://github.com/pooza/capsicum/issues/1087) `timelineProvider` の family 化 / [#1088](https://github.com/pooza/capsicum/issues/1088) family キー / [#1089](https://github.com/pooza/capsicum/issues/1089)・[#1090](https://github.com/pooza/capsicum/issues/1090) streaming の多重化 / [#1095](https://github.com/pooza/capsicum/issues/1095)・[#1096](https://github.com/pooza/capsicum/issues/1096) ProviderScope）は **provider と streaming の根を組み替える**。そして 1.x の不具合修正（ログイン・タイムライン・通知）も、ほぼ必ず同じ層に触る。長寿命ブランチを 2 本持つと、**その面積の乖離を挟んで毎回 cherry-pick する**ことになる。**乖離を抱えるブランチを `develop` 1 本に限る**のが要点。

**切り替えのトリガーは「develop に 1.x として出せない最初のコミットが入った瞬間」。**⚠ どのコミットがそれに当たるかは**系列の境界＝製品判断**（CLAUDE.md「マイルストーン運用」節）で、技術構造からは導けない。

## 実際に踏んだこと

- 切り替えのコミットは、pubspec を `2.0.0+185` へ上げた `9f5c5720`（2026-09-17）。
- ⚠ **タグのあとに develop へ入った現行系列向けのコミットは、main に無い。**v1.65.0 のタグ後に develop へ入った 3 本（Xcode 27 で iOS のリリースビルドが落ちる修正 `03547086` ほか）は、次の 1.x を出すときに cherry-pick が要った。**切り替えの前後に develop へ入れた現行系列向けの修正を、一覧にしておく。**
