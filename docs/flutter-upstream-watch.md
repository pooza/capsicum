# Flutter 上流バグの追跡

capsicum で発生する不具合のうち、原因が Flutter framework 本体または Flutter エコシステム（pub.dev のメンテパッケージ）側にあり、capsicum 側では根治できないものを集約する。月 1 回の chase routine で巡回し、上流の進捗を確認する。

## 監視対象

| capsicum | タイトル | 上流参照 | 最終確認日 | 状態 |
|---|---|---|---|---|
| [#54](https://github.com/pooza/capsicum/issues/54) | ATOK で日本語入力が二重になる (iOS) | iOS 特化の上流 issue 未発見。関連: [flutter/flutter#96092](https://github.com/flutter/flutter/issues/96092) (Android), [flutter/flutter#151103](https://github.com/flutter/flutter/issues/151103) / [#134926](https://github.com/flutter/flutter/issues/134926) (web) | 2026-05-02 | 上流 issue 未特定 |
| [#94](https://github.com/pooza/capsicum/issues/94) | 投稿フォームのテキスト選択メニューが英語表示・範囲選択不可 | [flutter/flutter#105028](https://github.com/flutter/flutter/issues/105028) (OPEN, TextField toolbar button text do not match platform iOS and macOS text in Japanese) | 2026-05-02 | 上流 open、本命特定 |
| [#276](https://github.com/pooza/capsicum/issues/276) | Android: ログイン画面から遷移しない (Custom Tab + `capsicum://` リダイレクト) | [ThexXTURBOXx/flutter_web_auth_2#187](https://github.com/ThexXTURBOXx/flutter_web_auth_2/issues/187) (Deeplink not working / bounce), [#198](https://github.com/ThexXTURBOXx/flutter_web_auth_2/issues/198) (Non-default browser opens), [#158](https://github.com/ThexXTURBOXx/flutter_web_auth_2/issues/158) (Browser doesn't close after callback), [#183](https://github.com/ThexXTURBOXx/flutter_web_auth_2/issues/183) (App Links docs clarity) | 2026-05-02 | 緩和策実装済み・上流複数 open |
| [#390](https://github.com/pooza/capsicum/issues/390) | macOS HardwareKeyboard assertion (リモート操作環境) | [flutter/flutter#180809](https://github.com/flutter/flutter/issues/180809) (CLOSED 2026-01-12, 同種 assertion の最新 close)。OPEN 類似: [#152391](https://github.com/flutter/flutter/issues/152391) (PDA keyboard SHIFT)。周辺: [#136419](https://github.com/flutter/flutter/issues/136419) (RawKeyboard deprecation tracking) | 2026-05-02 | 上流で繰り返し close→再現を周回。stable 反映と現行版での再現確認が必要 |
| [#481](https://github.com/pooza/capsicum/issues/481) | Sentry CAPSICUM-A: InkWell._startNewSplash で RenderBox not laid out (fatal × 3) | 上流 issue 未調査 | 2026-05-09 | in_app_frame_mix=system-only で capsicum 側コードがスタックに出ない。Flutter framework / Material InkWell の同種 issue を chase 時に探索 |

## chase 手順

1. 監視対象の各項目について、上流 Issue/PR の最新状態を確認する
   - `flutter/flutter` の場合: `gh -R flutter/flutter issue view <番号>` でステータス・直近コメントを確認
   - 他リポジトリ（`LinusU/flutter_web_auth_2` 等）も同様に `gh -R <owner/repo> issue view <番号>`
   - 関連 PR があれば `gh -R <owner/repo> pr view <番号>` で merge 状況を確認
2. 上流参照が「未調査」の項目は、capsicum 側 Issue の概要キーワードで `gh -R <owner/repo> issue list --search "..."` を実行し、有力候補（最大 3 件）を本 doc に追記する
3. 進展があった項目は capsicum 側 Issue にコメントを残す（上流の状態 + 次のアクション提案）
4. 本 doc の「最終確認日」と「状態」を更新する
5. 「修正済み（上流 close + 該当パッケージの stable に取り込み済み）」になった項目は、capsicum 側 Issue の close 候補として報告する（実際の close は動作確認後に pooza が判断するので、勝手に close しない）
6. 結果は doc 更新の commit + 必要に応じた capsicum 側 Issue へのコメント投稿で残す

## Flutter SDK / パッケージ バージョン管理との関係

capsicum は Flutter stable channel に固定している。上流修正が次回 stable に取り込まれる場合、次の stable リリース日を確認しておく（[Flutter Release Calendar](https://docs.flutter.dev/release/upgrade) を参照）。stable 更新時に本 doc の対象が一括で解消される可能性があるため、SDK 更新の判断材料としても活用する。

サードパーティパッケージ（`flutter_web_auth_2` 等）由来の項目は、当該パッケージの release notes / changelog を確認し、`pubspec.yaml` の更新で取り込めるかを判断する。

## routine

月次 chase は capsicum リポジトリの schedule routine で自動実行される（毎月 1 日 09:00 JST）。実行内容は本 doc の「chase 手順」に準ずる。
