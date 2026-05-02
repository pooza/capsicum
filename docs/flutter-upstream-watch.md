# Flutter 上流バグの追跡

capsicum で発生する不具合のうち、原因が Flutter framework 側にあり capsicum 側では根治できないものを集約する。月 1 回の chase routine で巡回し、上流の進捗を確認する。

## 監視対象

| capsicum | タイトル | Flutter 上流参照 | 最終確認日 | 状態 |
|---|---|---|---|---|
| [#54](https://github.com/pooza/capsicum/issues/54) | ATOK で日本語入力が二重になる (iOS) | (未調査 — IME composing text / ATOK で `flutter/flutter` を検索) | 2026-05-02 | 未調査 |
| [#94](https://github.com/pooza/capsicum/issues/94) | 投稿フォームのテキスト選択メニューが英語表示・範囲選択不可 | (未調査 — TextSelectionToolbar / MaterialLocalizations で `flutter/flutter` を検索) | 2026-05-02 | 未調査 |
| [#390](https://github.com/pooza/capsicum/issues/390) | macOS HardwareKeyboard assertion (リモート操作環境) | [flutter/flutter#136419](https://github.com/flutter/flutter/issues/136419), [flutter/flutter#167091](https://github.com/flutter/flutter/issues/167091) | 2026-05-02 | 上流 open、未確認 |

## 監視対象外（参考）

- [#276](https://github.com/pooza/capsicum/issues/276) ログイン画面遷移しない — Flutter 由来かどうか未確定 (reproduction-needed)。再現が取れた段階で監視対象に昇格を検討

## chase 手順

1. 監視対象の各項目について、Flutter 上流 Issue/PR の最新状態を確認する
   - `gh -R flutter/flutter issue view <番号>` でステータス・直近コメントを確認
   - 関連 PR があれば `gh -R flutter/flutter pr view <番号>` で merge 状況を確認
2. 上流参照が「未調査」の項目は、capsicum 側 Issue の概要キーワードで `gh -R flutter/flutter issue list --search "..."` を実行し、有力候補を本 doc に追記する
3. 進展があった項目は capsicum 側 Issue にコメントを残す（上流の状態 + 次のアクション提案）
4. 本 doc の「最終確認日」と「状態」を更新する
5. 「修正済み（上流 close + stable に取り込み済み）」になった項目は、capsicum 側 Issue の close 候補として報告する（実際の close は動作確認後に pooza が判断）
6. 結果は doc 更新の commit + 必要に応じた capsicum 側 Issue へのコメント投稿で残す

## Flutter SDK バージョン管理との関係

capsicum は Flutter stable channel に固定している。上流修正が次回 stable に取り込まれる場合、次の stable リリース日を確認しておく（[Flutter Release Calendar](https://docs.flutter.dev/release/upgrade) を参照）。stable 更新時に本 doc の対象が一括で解消される可能性があるため、SDK 更新の判断材料としても活用する。

## routine

月次 chase は capsicum リポジトリの schedule routine で自動実行される（毎月 1 日 09:00 JST）。実行内容は本 doc の「chase 手順」に準ずる。
