# Flutter 上流バグの追跡

capsicum で発生する不具合のうち、原因が Flutter framework 本体または Flutter エコシステム（pub.dev のメンテパッケージ）側にあり、capsicum 側では根治できないものを集約する。月 1 回の chase routine で巡回し、上流の進捗を確認する。

## 監視対象

| capsicum | タイトル | 上流参照 | 最終確認日 | 状態 |
|---|---|---|---|---|
| [#54](https://github.com/pooza/capsicum/issues/54) | ATOK で日本語入力が二重になる (iOS) | **iOS 本命起票済み: [flutter/flutter#187636](https://github.com/flutter/flutter/issues/187636)**（iOS ATOK 二重化。実機再現確認済み）。macOS 兄弟: [#149379](https://github.com/flutter/flutter/issues/149379) (OPEN) / 本質 [#160935](https://github.com/flutter/flutter/issues/160935) (CLOSED / r: fixed, #54 と同症状)。macOS 修正 PR [#166291](https://github.com/flutter/flutter/pull/166291) (MERGED 2025-06-21) は `darwin/macos/.../FlutterTextInputPlugin.mm` 1 ファイルのみ＝**macOS 専用、iOS 経路 (`darwin/ios/.../FlutterTextInputPlugin.mm`) は未修正**。関連: [#96092](https://github.com/flutter/flutter/issues/96092) (Android ATOK) / [#151103](https://github.com/flutter/flutter/issues/151103) / [#134926](https://github.com/flutter/flutter/issues/134926) (web) / [#154692](https://github.com/flutter/flutter/issues/154692) (Windows 同型) | 2026-06-06 | **iOS upstream #187636 起票完了**（macOS 修正 #166291 を範に iOS 同型修正を要請）。root-cause = darwin FlutterTextInputPlugin の IME composing 確定処理の二重適用。報告者情報（ATOK「従来のカーソル位置入力を使用」ON で回避可＝モダン inline composing 経路が触媒）と整合。次回 chase は #187636 のトリアージ状況を追う |
| [#94](https://github.com/pooza/capsicum/issues/94) | 投稿フォームのテキスト選択メニューが英語表示・範囲選択不可 | [flutter/flutter#105028](https://github.com/flutter/flutter/issues/105028) (OPEN, TextField toolbar button text do not match platform iOS and macOS text in Japanese) | 2026-06-02 | 上流 open、本命特定。上流の最終活動は 2024-03 で停滞。変化なし |
| [#276](https://github.com/pooza/capsicum/issues/276) | Android: ログイン画面から遷移しない (Custom Tab + `capsicum://` リダイレクト) | [ThexXTURBOXx/flutter_web_auth_2#187](https://github.com/ThexXTURBOXx/flutter_web_auth_2/issues/187) (Deeplink not working / bounce), [#198](https://github.com/ThexXTURBOXx/flutter_web_auth_2/issues/198) (Non-default browser opens), [#158](https://github.com/ThexXTURBOXx/flutter_web_auth_2/issues/158) (Browser doesn't close after callback), [#183](https://github.com/ThexXTURBOXx/flutter_web_auth_2/issues/183) (App Links docs clarity) | 2026-06-02 | 緩和策実装済み・上流 4 件すべて open のまま変化なし。flutter_web_auth_2 は 5.0.3 / 6.0.0-alpha が出たが内容は desktop_webview_window bump 中心で当該 issue の修正ではない |
| [#390](https://github.com/pooza/capsicum/issues/390) | macOS HardwareKeyboard assertion (リモート操作環境) | [flutter/flutter#180809](https://github.com/flutter/flutter/issues/180809) (CLOSED 2026-01-12, 同種 assertion の最新 close)。OPEN 類似: [#152391](https://github.com/flutter/flutter/issues/152391) (PDA keyboard SHIFT, 最終活動 2025-09)。周辺: [#136419](https://github.com/flutter/flutter/issues/136419) (RawKeyboard deprecation tracking) | 2026-06-02 | 上流で繰り返し close→再現を周回。stable 反映と現行版での再現確認が必要。変化なし |
| [#481](https://github.com/pooza/capsicum/issues/481) | Sentry CAPSICUM-A: InkWell._startNewSplash で RenderBox not laid out (fatal × 3) | 本命未特定。探索した弱候補: [flutter/flutter#141497](https://github.com/flutter/flutter/issues/141497) (OPEN, RenderBox not laid out: RenderFittedBox / OpenContainer+AppBar・animations 由来), [#147452](https://github.com/flutter/flutter/issues/147452) (OPEN, _debugSubtreeRelayoutRootAlreadyMarkedNeedsLayout assertion) | 2026-06-02 | in_app_frame_mix=system-only で capsicum 側コードがスタックに出ない。`_startNewSplash` / InkWell + "RenderBox not laid out" で探索したが InkWell splash 由来の本命は未発見。弱候補のみ記録 |
| [#463](https://github.com/pooza/capsicum/issues/463) | 入力エラー: かっこ等の変換が確定できずカーソルがワード左に飛ぶ (Android / Samsung Keyboard) | **本命: [flutter/flutter#120351](https://github.com/flutter/flutter/issues/120351)** (OPEN, "The operation of converting from Japanese strings to symbols on certain Android devices is bad", labels `e: samsung` / `a: text input` / `platform-android` / `a: internationalization` / `P2` / triaged-framework)。旧 close: [#31512](https://github.com/flutter/flutter/issues/31512) / [#51893](https://github.com/flutter/flutter/issues/51893) (Samsung composing region 重複, 2020 close) | 2026-06-02 | **chase で本命特定**。Samsung 端末で日本語→記号変換が不正という症状が #463 (かっこ等の変換確定不可) と一致。上流は triaged P2 だが最終活動 2024-02 で停滞。capsicum 側の全 TextField 共通触媒は棚卸し済みで該当なし。Gboard で回避可能 |

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
