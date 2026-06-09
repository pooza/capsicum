# 投稿サジェスト機能 設計（v1.35, #614）

## 位置付け

v1.35「投稿フォームのサジェスト」（[#614](https://github.com/pooza/capsicum/issues/614)）の設計。実況用途で、IME の変換候補に出てこない専門ワード（劇中ワード・キャラ名・必殺技名・カスタム絵文字ショートコード等）を、capsicum 側のアプリ独立サジェスト UI で補えるようにする。

出発点の要望: 辞書登録のない環境で `閃華裂光拳` のような専門ワードが IME 変換に出ず、1 文字ずつ変換するか Wikipedia からコピペするしかなく実況の即時性を損なう（起点: <https://misskey.delmulin.com/notes/ammp05oy3b>）。OS の IME は capsicum から制御できないため、**投稿フォーム内の独立サジェスト UI** として実装する。

## いちばん効く前提整理: 「もう在るもの」と「新規なもの」

[compose_screen.dart](../packages/capsicum/lib/src/ui/screen/compose_screen.dart) には既に**インライン補完が実装済み**である。設計はこの既存資産の上に積む。

| 補完 | トリガ | 実装 | 状態 |
|---|---|---|---|
| メンション `@` | `@` 入力 | `SearchSupport.searchUsers`（サーバー検索, debounce 300ms, 世代管理）→ ActionChip 横スクロール | **既存** |
| ハッシュタグ `#` | `#` 入力 | `SearchSupport.searchHashtags`（SNS 標準のタグ検索）→ 同上 | **既存** |
| カスタム絵文字 `:` | `:` 入力 | 起動時に全件先読み → **ローカル絞り込み**（サーバー往復なし）→ 同上 | **既存** |

→ #614 で**本当に新規なのは次の 3 点**:

1. **劇中ワード辞書サジェスト（読み付き）** — 既存 `#` 補完は SNS 標準のタグ検索で「読み」を持たない。`閃華裂光拳` のように **IME で字面を打てない語**を、**ひらがな読みから**引けるようにするのが本機能の心臓部。
2. **視聴中作品の話数** — モロヘイヤ `tagging/dic/annict/episodes`（「24話」等）。
3. **簡易投稿バーからの導線** — 実況の主導線である [simple_post_bar.dart](../packages/capsicum/lib/src/ui/widget/simple_post_bar.dart) には**フルのピッカー導線が無い**（最近使った絵文字の横ストリップのみ）。ここに補完を届けるのが要件。

## データ源: モロヘイヤに「読み付きサジェスト」を出してもらう（確定 2026-06-07）

### 経緯と判断

劇中ワード辞書の大元は MeCab IPADic 形式の単語辞書（例: precure.ml の `/api/dic/v1/dic.json`、約 2,860 語、Google Apps Script 配信）で、**表層形と読み（カタカナ）を持つ**。モロヘイヤはこれを含む複数ソースから辞書を組んでおり、`tagging/tag/search`（タグ検索 API）もこの系統に根ざす。ただし**タグ検索という用途で読みを落として公開している**ため、現状の tagging API からは読みが取れない。

→ **読みはモロヘイヤが内部に持っているのに露出していないだけ**。したがって:

- **capsicum は dic.json を直叩きしない。** モロヘイヤ側に「読みで引ける単語サジェスト」を露出してもらい、capsicum はそれを叩く。
- 理由:
  - **proxy 哲学**（[[feedback_mulukhiya_client_friendly_proxy]]）。MeCab 形式パース・複数ソース統合・正規化はモロヘイヤが担い、capsicum は単純判定だけ。
  - **サーバー検出問題が消える**。dic.json は precure.ml の GAS という個別事情。モロヘイヤのエンドポイント＋`/about` feature flag にすれば、annict / tagging と同じ検出パターンに乗り、デルムリン丼・ダイスキー等も同一 API で一律カバーできる（各サーバーが ~1,000 語辞書を組めばそのまま効く）。
  - capsicum が dic 直叩きだと「dic.json にしかない語」しか出ないが、モロヘイヤ経由なら**統合後**の辞書を引ける。

### API 契約（capsicum → モロヘイヤ、提案）

要件正本はモロヘイヤ [docs/capsicum-requirements.md](https://github.com/pooza/mulukhiya-toot-proxy/blob/develop/docs/capsicum-requirements.md)。本書は capsicum 側の必要仕様を示す。

- **エンドポイント（案）**: 既存 `tagging/tag/search` に読みを足すか、`GET /mulukhiya/api/word/suggest?q=...` を新設するか（モロヘイヤ側判断）。
- **入力**: `q`（ユーザー入力。**ひらがな/カタカナの読み**を主に想定。表層の前方一致も拾えると望ましい）、`limit`。
- **出力（案）**:
  ```json
  { "candidates": [
    { "surface": "愛崎えみる", "reading": "アイサキメグミ",
      "category": "人名", "tags": ["#プリキュア"] }
  ] }
  ```
  - `surface`: 挿入する表層形。
  - `reading`: 並べ替え・ハイライト用（カタカナ）。
  - `category`: 品詞細分類（人名 / 地域 / 一般 等）。ピッカーのカテゴリ別ブラウズに使う。
  - `tags`: 任意。挿入時にタグ自動付与へ繋げられる（別レイヤ）。
- **読み照合**: capsicum は入力ひらがなをカタカナ正規化して送る／またはモロヘイヤが両対応する（どちらが吸収するかは要件で確定）。
- **feature flag**: `GET /mulukhiya/api/about` の `features` に `word_suggest`（仮称）を追加。capsicum は [service.dart](../packages/capsicum_backends/lib/src/mulukhiya/service.dart) の `annictEnabled` と同じ場所でパースして UI 出し分け。

### 取得方式（capsicum 側）

辞書は ~0.5MB / 数千語と小さく静的に近いので、カスタム絵文字補完と**同じパターン**を採れる余地がある:

- 既存の絵文字補完: 起動時に全件先読み → ローカル絞り込み（サーバー往復ゼロ）。
- 劇中ワードも、サジェスト初回に**辞書を一括取得してキャッシュ**（ETag / TTL）し、以降はローカル絞り込みにすれば、実況の即時性・オフライン耐性が上がる。
- ただし「統合後辞書の一括取得 API」を出すか「都度クエリ API」にするかはモロヘイヤ側のコスト次第。**まずは都度クエリ（debounce）で実装し、一括取得は最適化として後追い**でよい。

## UI: 拡張ピッカー + 共有ランチャ + 簡易バー導線（確定 2026-06-07）

「絵文字ピッカーを拡張してタブを足す」方針（無難・部品再利用最大）で確定。

### ピッカー拡張

[emoji_picker.dart](../packages/capsicum/lib/src/ui/widget/emoji_picker.dart) は既にタブ構成（カスタム / Unicode）＋検索ボックス＋「最近使った」セクション＋モロヘイヤ palette 同期を持つ。ここに**タブを追加**する:

- **劇中ワード**タブ — 検索ボックスに**ひらがな読み**を入力 → 候補グリッド → タップで表層挿入。カテゴリ別ブラウズ（人名 / 地域 等）も可。
- **話数**タブ — `tagging/dic/annict/episodes`（annict 視聴中の作品 × 話数）。

各タブは既存カスタム絵文字タブと同形の検索 UI（[emoji_picker.dart §カスタムタブ](../packages/capsicum/lib/src/ui/widget/emoji_picker.dart)）を踏襲する。

### 共有ランチャ

compose 側のピッカー起動（[compose_screen.dart `_showEmojiPicker`](../packages/capsicum/lib/src/ui/screen/compose_screen.dart)）を**共有ランチャ**（`showInsertPickerSheet(...)` 仮称）に切り出し、**compose と簡易投稿バーの両方から同じ拡張ピッカーを開く**。実装が 1 箇所に集約され、劇中ワード/話数タブが両画面で自動的に使える。

### 簡易投稿バー導線（本機能の主眼）

[simple_post_bar.dart](../packages/capsicum/lib/src/ui/widget/simple_post_bar.dart) の現状:

- ボタン列は `[キーボードしまう?] [絵文字履歴トグル?] [詳細画面へ] [送信]`。
- 「絵文字履歴トグル」は**最近使った絵文字の横ストリップ**を開くのみ（`_buildPalette`）。しかも `if (hasRecents)` 条件付きで履歴が無いと出ない。
- フルピッカーへの導線は無く、使うには「詳細画面へ」で compose に飛ぶしかない＝実況の即時性を損なう。

対応:

- 簡易バーに**「ピッカーを開く」ボタンを 1 個追加**し、共有ランチャで拡張ピッカーを開く。
- 既存の「最近使った横ストリップ」は**速い挿入経路として残す**（実況で頻出絵文字を 1 タップ）。＝ストリップ（高速）＋ピッカーボタン（全機能）の二段構え。
- 拡張ピッカーは「最近使った」を先頭セクションに持つので、`hasRecents` 依存の穴（履歴ゼロのユーザー）もボタン 1 つで埋まる。
- アイコンは履歴（時計系）とピッカー（グリッド/絵文字系）で分けて区別する。

### インライン発火問題は「ピッカー専用で出荷」で回避

`:` `#` `@` と違い、ひらがなには専用トリガー文字が無く、普通の入力と劇中ワード検索の区別が難しい（常時オンはノイズ、トリガーキーは一手間）。

→ 劇中ワードタブは**ピッカー内の自前検索ボックス**でひらがな読みを打って絞り込む方式とし、**インライン発火（本文打鍵中の自動候補）は v1.35 では入れない**。最小リスクで出荷し、インライン読み補完（本文入力中に読みから候補表示）は反応を見て後追いする。

## サジェスト元の整理（3 系統）

1. **劇中ワード（読み付き）** — モロヘイヤの読み付きサジェスト（上記）。モロヘイヤ導入サーバーのみ。
2. **視聴中作品の話数** — モロヘイヤ `tagging/dic/annict/episodes`。annict 連携時のみ。
3. **カスタム絵文字ショートコード** — モロヘイヤ非依存。**インライン `:` 補完は既存**。ピッカーのカスタム絵文字タブも既存。本機能では simple_post_bar からの導線追加で恩恵が及ぶ。

## 適用範囲

- **compose 本文** — 既存補完 + 拡張ピッカー。
- **簡易投稿バー** — 拡張ピッカー導線を追加（主眼）。
- **CW 欄 / リプライ / Misskey メッセージ入力** — 各々独立の `TextEditingController`（[chat_thread_screen.dart](../packages/capsicum/lib/src/ui/screen/chat_thread_screen.dart) 等）。v1.35 では**対象外**（本文と簡易バーに集中）。共有ランチャ化により後で広げやすくはしておく。

## 段階リリースとスコープ

1. モロヘイヤ側 読み付きサジェスト API + `/about` feature flag（**要件起票・上流リードタイム**）。
2. capsicum: 共有ランチャ切り出し（compose のピッカー起動を共通化）。
3. capsicum: 拡張ピッカーに劇中ワード/話数タブ追加（読み検索 = ピッカー内検索ボックス）。
4. capsicum: 簡易投稿バーにピッカーボタン追加（ストリップは残す）。
5. 検証: 自前サーバー（キュアスタ！/きゅあすきー は辞書あり、デルムリン丼/ダイスキー は辞書整備後）で内部ベータ検証。

## 未確定・要判断

| # | 論点 | 暫定方針 |
|---|---|---|
| 1 | 読み付き API を既存 `tagging/tag/search` 拡張にするか新設するか | モロヘイヤ側判断。capsicum は読みが取れれば形は問わない |
| 2 | ひらがな↔カタカナ正規化を capsicum / モロヘイヤどちらが吸収するか | 要件で確定。proxy 哲学的にはモロヘイヤ寄せが自然 |
| 3 | 辞書取得を都度クエリ / 一括取得+ローカル絞り込み | まず都度クエリ。一括取得は最適化として後追い |
| 4 | インライン読み補完（本文打鍵中の自動候補） | v1.35 では入れない。ピッカー専用で出荷し後追い |
| 5 | CW / リプライ / メッセージへの拡大 | v1.35 対象外。共有ランチャ化で将来容易に |
| 6 | デルムリン丼・ダイスキーの ~1,000 語辞書整備 | pooza のコンテンツ作業。capsicum 実装とは独立 |

## モロヘイヤ側の含意（要件起票）

- 読みで引ける単語サジェスト API の露出（既存 tag 検索に `reading` 追加 or `word/suggest` 新設）。
- `/about` `features` への `word_suggest`（仮称）追加。
- 要件正本はモロヘイヤ [docs/capsicum-requirements.md](https://github.com/pooza/mulukhiya-toot-proxy/blob/develop/docs/capsicum-requirements.md) §。capsicum → モロヘイヤの起票で連携する。

## 関連

- [#614](https://github.com/pooza/capsicum/issues/614) 投稿サジェスト機能（本書の実装元）
- 既存補完・ピッカー: [compose_screen.dart](../packages/capsicum/lib/src/ui/screen/compose_screen.dart) / [emoji_picker.dart](../packages/capsicum/lib/src/ui/widget/emoji_picker.dart) / [simple_post_bar.dart](../packages/capsicum/lib/src/ui/widget/simple_post_bar.dart)
- モロヘイヤ連携: [service.dart](../packages/capsicum_backends/lib/src/mulukhiya/service.dart) / モロヘイヤ docs/capsicum-requirements.md
- 劇中ワード辞書の大元（参考）: precure.ml `/api/dic/v1/dic.json`（MeCab IPADic 形式・読み付き）
