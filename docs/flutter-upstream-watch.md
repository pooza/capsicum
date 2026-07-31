# Flutter 上流バグの追跡

capsicum で発生する不具合のうち、原因が Flutter framework 本体または Flutter エコシステム（pub.dev のメンテパッケージ）側にあり、capsicum 側では根治できないものを集約する。月 1 回の chase routine で巡回し、上流の進捗を確認する。

## 監視対象

| capsicum | タイトル | 上流参照 | 最終確認日 | 状態 |
|---|---|---|---|---|
| [#54](https://github.com/pooza/capsicum/issues/54) | ATOK で日本語入力が二重になる (iOS) | **iOS 本命起票済み: [flutter/flutter#187636](https://github.com/flutter/flutter/issues/187636)**（iOS ATOK 二重化。実機再現確認済み）。macOS 兄弟: [#149379](https://github.com/flutter/flutter/issues/149379) (OPEN) / 本質 [#160935](https://github.com/flutter/flutter/issues/160935) (CLOSED / r: fixed, #54 と同症状)。macOS 修正 PR [#166291](https://github.com/flutter/flutter/pull/166291) (MERGED 2025-06-21) は `darwin/macos/.../FlutterTextInputPlugin.mm` 1 ファイルのみ＝**macOS 専用、iOS 経路 (`darwin/ios/.../FlutterTextInputPlugin.mm`) は未修正**。関連: [#96092](https://github.com/flutter/flutter/issues/96092) (Android ATOK) / [#151103](https://github.com/flutter/flutter/issues/151103) / [#134926](https://github.com/flutter/flutter/issues/134926) (web) / [#154692](https://github.com/flutter/flutter/issues/154692) (Windows 同型) | 2026-08-01 | 前回のトリアージ（`P2` / `team-text-input` / `triaged-text-input` / `has reproducible steps` / `engine`）から**変化なし**。OPEN・最終更新 2026-06-11・コメント 0 件のまま＝オーナーは付いたが着手はされていない。root-cause = darwin FlutterTextInputPlugin の IME composing 確定処理の二重適用。引き続き #187636 のコメント・PR を追う |
| [#94](https://github.com/pooza/capsicum/issues/94) | 投稿フォームのテキスト選択メニューが英語表示・範囲選択不可 | [flutter/flutter#105028](https://github.com/flutter/flutter/issues/105028) (OPEN, TextField toolbar button text do not match platform iOS and macOS text in Japanese) | 2026-08-01 | 上流 open、本命特定済。最終更新 2024-03-06・実質的な議論は 2023-08 が最後（翻訳文字列を Apple 系 / Windows 系で分ける必要があるという結論のまま停滞）。変化なし |
| [#390](https://github.com/pooza/capsicum/issues/390) | macOS HardwareKeyboard assertion (リモート操作環境) | **本命特定: [flutter/flutter#125975](https://github.com/flutter/flutter/issues/125975)**（OPEN / `r: solved` / `has partial patch`、"Pressing and releasing a key before the framework has started throws"）。従来追っていた [#180809](https://github.com/flutter/flutter/issues/180809) は **#125975 の duplicate として close**（2026-01-12）＝周回していた close 群の集約先がここ。**修正 PR: [#181894](https://github.com/flutter/flutter/pull/181894)**（MERGED 2026-02-10, "Disable hardware keyboard regularity warning by default"）。不採用の partial patch: [#172154](https://github.com/flutter/flutter/pull/172154) (CLOSED)。OPEN 類似: [#152391](https://github.com/flutter/flutter/issues/152391) (PDA keyboard SHIFT, 最終活動 2025-09)。周辺: [#136419](https://github.com/flutter/flutter/issues/136419) (RawKeyboard deprecation tracking) | 2026-08-01 | **close 候補（要動作確認）**。#390 本文の `hardware_keyboard.dart:516 '!_pressedKeys.containsKey(event.physicalKey)'` は **pinned SDK（Flutter 3.44.6 / framework rev ee80f08bbf・2026-07-08）の同ファイルに既に存在しない**。#181894 で hard assert が廃止され、`_logEventIfIrregular`（L509-）が `debugPrintKeyboardEvents` == true のときだけ `debugPrint` する形に置換された。既定では false なので**赤画面は構造的に発生しない**。上流 #125975 が OPEN のままなのは debugPrintKeyboardEvents 有効時に再現が残るため（capsicum は無影響）。RustDesk リモート操作での再現が無いことを確認できたら close 可 |
| [#481](https://github.com/pooza/capsicum/issues/481) | Sentry CAPSICUM-A: InkWell._startNewSplash で RenderBox not laid out (fatal × 3) | 本命未特定。探索した弱候補: [flutter/flutter#141497](https://github.com/flutter/flutter/issues/141497) (OPEN, RenderBox not laid out: RenderFittedBox / OpenContainer+AppBar・animations 由来), [#147452](https://github.com/flutter/flutter/issues/147452) (OPEN, _debugSubtreeRelayoutRootAlreadyMarkedNeedsLayout assertion) | 2026-08-01 | in_app_frame_mix=system-only で capsicum 側コードがスタックに出ない。`_startNewSplash` / InkWell + "RenderBox not laid out" で探索したが InkWell splash 由来の本命は未発見。弱候補（#141497 最終更新 2025-08-29 / #147452 同 2025-06-03）とも動きなし。変化なし |
| [#463](https://github.com/pooza/capsicum/issues/463) | 入力エラー: かっこ等の変換が確定できずカーソルがワード左に飛ぶ (Android / Samsung Keyboard) | **本命: [flutter/flutter#120351](https://github.com/flutter/flutter/issues/120351)** (OPEN, "The operation of converting from Japanese strings to symbols on certain Android devices is bad", labels `e: samsung` / `a: text input` / `platform-android` / `a: internationalization` / `P2` / triaged-framework)。旧 close: [#31512](https://github.com/flutter/flutter/issues/31512) / [#51893](https://github.com/flutter/flutter/issues/51893) (Samsung composing region 重複, 2020 close) | 2026-08-01 | **chase で本命特定済**。Samsung 端末で日本語→記号変換が不正という症状が #463 (かっこ等の変換確定不可) と一致。上流は triaged-framework P2 だが最終更新 2024-02-20 で停滞のまま（担当者は 2024-02 に triage bot が解除して以降 未アサイン）。capsicum 側の全 TextField 共通触媒は棚卸し済みで該当なし。Gboard で回避可能。変化なし |

## close 候補

上流が修正済みで、かつ pinned SDK に取り込み済みと確認できた項目。**実際の close は pooza が動作確認してから判断する**（chase 側では close しない）。

- **[#390](https://github.com/pooza/capsicum/issues/390) macOS HardwareKeyboard assertion**（2026-08-01 chase で判定）— 上流 [flutter#181894](https://github.com/flutter/flutter/pull/181894) で hard assert が廃止され、Flutter 3.44.6 の `hardware_keyboard.dart` に該当 assert が存在しないことを直接確認済み。確認手順は RustDesk で Linux → Mac のリモート操作をしながら macOS 版にログインし、赤画面が出ないこと。

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

あわせて月次巡回のついでに、**資格情報の満了チェック**も実施する（infra-note〔chubo2, private〕の「資格情報の満了一覧」§の月次チェック手順）。chubo2 を参照できる環境では満了 60 日 / 30 日以内の資格情報を報告し、参照できない環境ではスキップしてその旨を残す（満了日そのものは private な infra-note 側が正本。公開リポジトリには書かない）。
