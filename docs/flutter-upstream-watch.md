# Flutter 上流バグの追跡

capsicum で発生する不具合のうち、原因が Flutter framework 本体または Flutter エコシステム（pub.dev のメンテパッケージ）側にあり、capsicum 側では根治できないものを集約する。月 1 回の chase routine で巡回し、上流の進捗を確認する。

⚠ **監視対象テーブルの母数は「`flutter` ラベルが付いた open Issue」**。chase の最初に `gh issue list --label flutter --state open` を実行し、テーブルとの差分（未掲載の open / 掲載済みだが close 済み）を先に解消してから上流を追う。2026-08-21 の同期で、close 済みの #390 / #481 が残り open の #608 が載っていない状態を検出した — **上流だけ見ていると capsicum 側の状態変化に気付けない**。

## 監視対象

| capsicum | タイトル | 上流参照 | 最終確認日 | 状態 |
|---|---|---|---|---|
| [#54](https://github.com/pooza/capsicum/issues/54) | ATOK で日本語入力が二重になる (iOS) | **iOS 本命起票済み: [flutter/flutter#187636](https://github.com/flutter/flutter/issues/187636)**（iOS ATOK 二重化。実機再現確認済み）。macOS 兄弟: [#149379](https://github.com/flutter/flutter/issues/149379) (OPEN) / 本質 [#160935](https://github.com/flutter/flutter/issues/160935) (CLOSED / r: fixed, #54 と同症状)。macOS 修正 PR [#166291](https://github.com/flutter/flutter/pull/166291) (MERGED 2025-06-21) は `darwin/macos/.../FlutterTextInputPlugin.mm` 1 ファイルのみ＝**macOS 専用、iOS 経路 (`darwin/ios/.../FlutterTextInputPlugin.mm`) は未修正**。関連: [#96092](https://github.com/flutter/flutter/issues/96092) (Android ATOK) / [#151103](https://github.com/flutter/flutter/issues/151103) / [#134926](https://github.com/flutter/flutter/issues/134926) (web) | 2026-09-01 | 前回のトリアージ（`P2` / `team-text-input` / `triaged-text-input` / `has reproducible steps` / `engine`）から**変化なし**。OPEN・最終更新 2026-06-11・コメント 0 件・assignee `LongCatIsLooong` のまま＝オーナーは付いたが着手はされていない。`gh -R flutter/flutter pr list --search "187636"` も 0 件で、修正 PR は存在しない。root-cause = darwin FlutterTextInputPlugin の IME composing 確定処理の二重適用。引き続き #187636 のコメント・PR を追う。⚠ **2026-09-01 訂正: 関連として併記していた [#154692](https://github.com/flutter/flutter/issues/154692) は Windows ではない** — 実際は `platform-android` で、Microsoft SwiftKey 翻訳キーボード使用時の重複（"Text Duplication Issue with Microsoft Translate Keyboard"）。「Windows 同型」は誤りだったので削除した（#608 の探索起点としても無効） |
| [#94](https://github.com/pooza/capsicum/issues/94) | 投稿フォームのテキスト選択メニューが英語表示・範囲選択不可 | [flutter/flutter#105028](https://github.com/flutter/flutter/issues/105028) (OPEN, TextField toolbar button text do not match platform iOS and macOS text in Japanese) | 2026-09-01 | 上流 open、本命特定済。最終更新 2024-03-06・実質的な議論は 2023-08 が最後（翻訳文字列を Apple 系 / Windows 系で分ける必要があるという結論のまま停滞）。未アサイン。変化なし |
| [#463](https://github.com/pooza/capsicum/issues/463) | 入力エラー: かっこ等の変換が確定できずカーソルがワード左に飛ぶ (Android / Samsung Keyboard) | **本命: [flutter/flutter#120351](https://github.com/flutter/flutter/issues/120351)** (OPEN, "The operation of converting from Japanese strings to symbols on certain Android devices is bad", labels `e: samsung` / `a: text input` / `platform-android` / `a: internationalization` / `P2` / triaged-framework)。旧 close: [#31512](https://github.com/flutter/flutter/issues/31512) / [#51893](https://github.com/flutter/flutter/issues/51893) (Samsung composing region 重複, 2020 close) | 2026-09-01 | **chase で本命特定済**。Samsung 端末で日本語→記号変換が不正という症状が #463 (かっこ等の変換確定不可) と一致。上流は triaged-framework P2 だが最終更新 2024-02-20 で停滞のまま（担当者は 2024-02 に triage bot が解除して以降 未アサイン）。capsicum 側の全 TextField 共通触媒は棚卸し済みで該当なし。Gboard で回避可能。変化なし |
| [#608](https://github.com/pooza/capsicum/issues/608) | Windows: IME 変換中にカーソルが文節先頭に固着し一時的に入力不能になる | **2026-09-01 の chase で候補 3 件を特定（本命は未確定）**。① **[flutter/flutter#189491](https://github.com/flutter/flutter/issues/189491)**「[Windows] Windows Hangul syllable loss」(OPEN / P2 / `team-windows` / `triaged-windows` / `has reproducible steps`) — **最有力**。② [#126263](https://github.com/flutter/flutter/issues/126263)「[TextField] Odd behavior with Microsoft IME Japanese Text input method」(OPEN / P2 / `c: regression` / team-windows)。③ [#191196](https://github.com/flutter/flutter/issues/191196)「[Windows] IME composition survives a text-client change」(OPEN / P3) | 2026-09-01 | ⚠ **本命は未確定**。`reproduction-needed` のままで **Windows 実機での再現手順が先**（[dev-environment.md](dev-environment.md) の実機ゲート）。候補の当たり具合: **① が「打鍵が失われ、同じ文字を打ち直す必要がある」と一致**（IME/event の timing で syllable が落ちる・高速入力時に出やすく毎回は再現しない＝#608 の「たまに」と同じ非決定性）。上流も生きており 2026-07-29 に loic-sharma が [#140739](https://github.com/flutter/flutter/issues/140739) の contributor へ修正を打診、最終更新 2026-08-06。② は Windows + 日本語 IME だが症状が「重複」で、#608 の「固着・入力不能」とは別系統（2024-06 停滞）。③ は別 TextField への遷移が要るので #608 の状況とは合わない。⚠ **capsicum #608 の本文が参考に挙げている [flutter#103203](https://github.com/flutter/flutter/issues/103203) は無関係**（`r: invalid` で 2022-05 close された assertion メッセージの別件。「Windows TSF の TextEditingDelta 取りこぼし系統」という説明は成り立たない） |

### 監視対象に入れていない `flutter` ラベル付き Issue

手順 0 の突き合わせで出た差分のうち、**上流待ちではないので監視対象テーブルに載せないもの**。⚠ 次回の chase で「未掲載の open」として再検出しないよう、理由をここに残す。

| capsicum | 判定日 | 監視対象にしない理由 |
|---|---|---|
| [#1057](https://github.com/pooza/capsicum/issues/1057) Android: OAuth 認可は成功しているのにログイン画面から遷移しない | 2026-09-01 | **capsicum 側で根治でき、[v1.64](https://github.com/pooza/capsicum/milestone/78) で修正予定**。誘因は Android のキャッシュアプリ freezer（loopback OAuth callback 中にアプリが凍結される）で Flutter framework のバグではなく、落ちているのは `_finishLogin` の `if (!mounted) return;` 後のフォールバック不在という capsicum 側の設計。**追う上流 Issue が無い**ので本テーブルの母数から外す。⚠ `flutter` ラベルは「プラットフォーム挙動が誘因」の意味で付いたと見られるが、本 doc の母数定義（手順 0）と食い違うため、**ラベルを外すかどうかは pooza 判断**（この行はその判断が付くまでの覚え書き） |

## close 候補

上流が修正済みで、かつ pinned SDK に取り込み済みと確認できた項目。**実際の close は pooza が動作確認してから判断する**（chase 側では close しない）。

現在なし。直近の掲載は #390（macOS HardwareKeyboard assertion）で、2026-08-01 の chase が「上流 [flutter#181894](https://github.com/flutter/flutter/pull/181894) で hard assert 廃止・pinned SDK に該当 assert なし」と判定し、**2026-08-10 に pooza が動作確認して close 済み**。

## 卒業した項目

監視対象テーブルから外した項目。⚠ **capsicum 側 Issue が close されたら、上流が OPEN のままでもテーブルから外す**（上流の進捗を追う理由が無くなるため）。

| capsicum | 外した日 | 理由 |
|---|---|---|
| [#390](https://github.com/pooza/capsicum/issues/390) macOS HardwareKeyboard assertion | 2026-08-21 | 2026-08-10 に close 済み。上流 [flutter#125975](https://github.com/flutter/flutter/issues/125975) は OPEN のままだが、`debugPrintKeyboardEvents` 有効時のみ再現＝capsicum は無影響 |
| [#481](https://github.com/pooza/capsicum/issues/481) InkWell.\_startNewSplash で RenderBox not laid out | 2026-08-21 | 2026-07-22 に close 済み。上流の本命は最後まで未特定だった |

## chase 手順

0. **テーブルの母数を先に合わせる。** `gh issue list --label flutter --state open` を実行し、監視対象テーブルとの差分を解消する（未掲載の open は追加・close 済みの行は「卒業した項目」へ移す）。⚠ **上流だけ見ていると capsicum 側の状態変化に気付けない**（2026-08-01 の chase が close 済みの #481 を「変化なし」と更新していた実例がある）
1. 監視対象の各項目について、上流 Issue/PR の最新状態を確認する
   - `flutter/flutter` の場合: `gh -R flutter/flutter issue view <番号>` でステータス・直近コメントを確認
   - 他リポジトリ（`LinusU/flutter_web_auth_2` 等）も同様に `gh -R <owner/repo> issue view <番号>`
   - 関連 PR があれば `gh -R <owner/repo> pr view <番号>` で merge 状況を確認
   - **上流が CLOSED の項目は「行き止まり」と扱わず、`stateReason` を必ず見る**。`DUPLICATE` なら close コメントに書かれた集約先まで辿り、そこで修正 PR の有無を確認する。`--json state,stateReason,comments` を付けると 1 回で判る。2026-08 の chase で #390 の本命（[flutter#125975](https://github.com/flutter/flutter/issues/125975)）はこの経路で見つかった — 追跡先の [#180809](https://github.com/flutter/flutter/issues/180809) は 2026-01 に duplicate close されており、半年間「CLOSED のまま・変化なし」と記録し続けていた
   - 修正 PR が merge 済みだった場合、**stable への取り込みは pinned SDK のソースを直接読んで確認する**のが最も確実（`$(dirname $(dirname $(readlink -f $(which flutter))))/packages/flutter/...` を grep する）。リリースノートより早く白黒が付く
2. 上流参照が「未調査」の項目は、capsicum 側 Issue の概要キーワードで `gh -R <owner/repo> issue list --search "..."` を実行し、有力候補（最大 3 件）を本 doc に追記する
3. 進展があった項目は capsicum 側 Issue にコメントを残す（上流の状態 + 次のアクション提案）
4. 本 doc の「最終確認日」と「状態」を更新する
5. 「修正済み（上流 close + 該当パッケージの stable に取り込み済み）」になった項目は、capsicum 側 Issue の close 候補として報告する（実際の close は動作確認後に pooza が判断するので、勝手に close しない）
6. 結果は doc 更新の commit + 必要に応じた capsicum 側 Issue へのコメント投稿で残す

## Flutter SDK / パッケージ バージョン管理との関係

capsicum は Flutter stable channel に固定している。上流修正が次回 stable に取り込まれる場合、次の stable リリース日を確認しておく（[Flutter Release Calendar](https://docs.flutter.dev/release/upgrade) を参照）。stable 更新時に本 doc の対象が一括で解消される可能性があるため、SDK 更新の判断材料としても活用する。

**pin の正本は CI ワークフローの `flutter-version`**（`analyze.yml` / `linux-release.yml` / `windows-release.yml` の 3 本に同じ値が書かれている）。chase のたびに実測して落差を記録する:

```
grep -n 'flutter-version' .github/workflows/*.yml
curl -s https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json \
  | jq -r '[.releases[]|select(.channel=="stable")]|map({version,release_date})|unique_by(.version)|sort_by(.release_date)|reverse|.[0:8][]|"\(.version)\t\(.release_date[0:10])"'
```

| 確認日 | pin | 最新 stable | 落差 |
|---|---|---|---|
| 2026-09-01 | **3.44.6**（2026-07-09） | **3.47.2**（2026-08-27） | マイナー 1 つ分。同じ 3.44 系にも 3.44.7 / .8 / .9 のパッチが出ている。⚠ **本 doc の 4 件はいずれも上流未修正なので、SDK を上げても解消しない**。上げる動機は別（一般の不具合修正・依存の追従）なので、リリース枠の判断は chase と切り離す |

サードパーティパッケージ（`flutter_web_auth_2` 等）由来の項目は、当該パッケージの release notes / changelog を確認し、`pubspec.yaml` の更新で取り込めるかを判断する。

## 実行タイミング（2026-08-21 に手動運用へ切り替え）

⚠ **クラウドの schedule routine は 2 本とも無効化した。月初に手元のセッションで回す。**

「月初にこれを実行するのは案外おぼえている」（pooza）ので、月初のセッションで **「Flutter の chase をやって」** と指示すれば足りる。実行内容は本 doc の「chase 手順」に準ずる。

### なぜ自動化をやめたか

routine は 2026-05 / 06 / 07 / 08 と 4 か月連続で発火していたが、**develop に成果コミットを 1 件も残していなかった**。実務は毎回ローカルセッションが先回りして済ませており、2026-08-01 は routine の発火（09:04 JST）の 2 時間前にローカルが chase を終えていた。

⚠ **さらに、クラウド巡回の prompt には構造的な穴があった。** 手順が「上流 Issue/PR の状態を見る」だけで、**capsicum 側の状態を見るステップが無い**。実際 #481 は 2026-07-22 に close 済みだったのに、10 日後の chase が監視テーブルの #481 行を「変化なし」と更新していた。手動で回す場合も**この穴は踏みうる**ので、chase 手順 0（テーブルと `--label flutter --state open` の突き合わせ）を必ず先にやる。

⚠ **完全削除は <https://claude.ai/code/routines> からしかできない**（API では無効化止まり）。トリガー ID は `trig_01UyYc13dKiRLFKfWWvurMje`（本命）/ `trig_01LEdYNHZXkyjyYbhyFghyWU`（重複・2026-08-01 に無効化済み）。

### ⚠ 一緒に止まったもの: 資格情報の満了チェック

月次巡回に**相乗りさせていた**ため、これも自動では回らなくなった。chase と同じタイミングで手動実施する — infra-note〔chubo2, private〕の「資格情報の満了一覧」§の月次チェック手順に従い、chubo2 を参照できる環境では満了 60 日 / 30 日以内の資格情報を報告する（満了日そのものは private な infra-note 側が正本。公開リポジトリには書かない）。**直近で最も近い満了は WNS 資格情報の 2028-06-22** なので当面の切迫はないが、chase と切り離すと今度はこちらが忘れられる点に注意。

⚠ **チェックは A・B 表の突き合わせで終わりにしない。**infra-note の月次手順は 3 ステップあり、3 番目が**「要確認」行の実満了日を調べて埋める**。ここが毎回スキップされていて、2026-09-01 時点でも 2 行が未記入のまま残っている（区分 D の msstore CLI クライアントシークレット / 区分 B の Apple Developer Program メンバーシップ）。**満了 60 日以内が 0 件でも「対応なし」で閉じない** — 未記入行は「切迫していない」ことすら確認できていない状態なので、報告に残す。
