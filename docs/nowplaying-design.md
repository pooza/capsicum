# プレイヤー横断ナウプレ取得 設計（v1.33）

## 位置付け

v1.33「NowPlaying 横断対応」の **抽象設計**。3 つの Issue を 1 つのアーキテクチャに束ねる:

- [#466](https://github.com/pooza/capsicum/issues/466) `NowPlayingProvider` 抽象層 + **Linux MPRIS**（+ macOS）
- [#484](https://github.com/pooza/capsicum/issues/484) **Windows SMTC**（#466 の抽象に乗せる Windows 実装）
- [#570](https://github.com/pooza/capsicum/issues/570) **Spotify**（mulukhiya 経由 OAuth + currently-playing）

Spotify 単体の詳細フロー（OAuth・mulukhiya エンドポイント・エッジケース）は [spotify-nowplaying-design.md](spotify-nowplaying-design.md) が正本。本書はそれを **1 つの取得源** として抽象に組み込む立場で、源の選択・整形・プラットフォーム実装方針を確定する。

## いちばん効く設計判断: 「2 軸」を取り違えない

既存のプラットフォーム抽象（`BackgroundTaskScheduler` #328 / `MediaPicker` #329 / `NotificationSubsystem` #330）は **OS ごとに実装を 1 つ選ぶ** factory パターン。NowPlaying は **これに当てはまらない**。取得源が 2 軸あるため:

1. **OS ネイティブ源** — Linux=MPRIS / Windows=SMTC / macOS=Share Extension（push）。OS で実装が変わる（既存 factory と同じ軸）
2. **Spotify 源** — mulukhiya 経由。**OS 非依存**で、かつ「当該アカウントが Spotify 連携済み」という **実行時条件**でのみ使える

したがって「OS で 1 実装を選ぶ」のではなく、**優先順位つきの合成リゾルバ**にする（#466 が要求する「OAuth 連携済み Spotify > OS API > フォールバック」）。

```
NowPlayingResolver.currentlyPlaying():
  1. spotifyEnabled && spotifyLinked なら SpotifyNowPlayingProvider を試す → 取れたら返す
  2. OS ネイティブ provider（MPRIS / SMTC / なし）を試す → 取れたら返す
  3. どちらも null → null（呼び出し側は「再生中の曲がありません」）
```

Spotify を最優先にするのは、**URL を返せる唯一の源**だから（後述）。

## もう 1 つの肝: URL を持つ源と持たない源

| 源 | 返せるもの | 投稿への入れ方 |
|---|---|---|
| Spotify（mulukhiya） | `https://open.spotify.com/track/...`（**URL あり**） | URL をそのまま本文へ。SNS / モロヘイヤが unfurl |
| MPRIS / SMTC | title / artist / album / artwork（**URL なし、文字情報のみ**） | 文字 → ナウプレ整形が必要 |
| Share Extension（push） | 共有元アプリが渡す URL or テキスト | 既存は `#nowplaying {text}` 直挿入 |

文字情報しか無い源（MPRIS / SMTC）の **整形はクライアント（capsicum）側で完結する**（下記 §責務分担、2026-06-05 確定）:

- **capsicum 側整形 `formatNowPlayingFallback`** — title/artist/album から `#nowplaying` 行を組む唯一の整形器。モロヘイヤ配備の有無・オンライン/オフラインに関わらずこれが主経路（"fallback" は歴史的命名）。
- モロヘイヤに **テキスト整形ハンドラ（旧称 `text_nowplaying_formatter`）は新設しない**。整形をサーバーへ往復させない方針に確定したため。モロヘイヤ側のナウプレ責務は **URL enrich（メタ → 共有 URL、#4382）のみ**で、これは URL を持たない源への **任意の上積み**（capsicum #669）。

> **訂正（2026-06-07）**: 当初は「文字情報源のためにモロヘイヤ `text_nowplaying_formatter` を起票する」案だったが、下記 §責務分担の確定（整形=クライアント / サーバーはテキスト整形しない）により撤回。formatter ハンドラの起票は不要。

`NowPlayingInfo.url != null` なら URL をそのまま挿入、`null` なら capsicum 側整形へ。`null` の源には任意でモロヘイヤ enrich（#4382）を挟んで URL を補完できる（#669、optional）。

## 責務分担: 整形はクライアント / API プロキシ（URL enrich）はサーバー（2026-06-05 確定）

ナウプレ処理をクライアント（capsicum）とサーバー（モロヘイヤ）でどう分けるかを確定した。

**原則**:

- **整形（Title/Album/Artist のレイアウト・`#nowplaying` タグ位置・行構成）はクライアント側**で行う。OS pull（MPRIS / SMTC / Apple Music）で構造化メタデータを持っている側が組むのが筋。[`formatNowPlayingFallback`](../packages/capsicum/lib/src/util/now_playing_formatter.dart) がその実体で、これが**主経路**（"fallback" は歴史的命名で、実際は唯一の整形器）。
- **外部 API の秘密情報・fetch が要る部分（メタデータ → 共有可能 URL の解決、URL → メタデータ抽出）はサーバー（モロヘイヤ）側**に置く。Spotify / iTunes の API キーはサーバー保持で、capsicum は「title/artist を渡して URL をもらう」明示的な API 呼び出しで使う（フロントの処理を軽くする本来のプロキシ設計）。

**背景**:

旧来モロヘイヤは投稿を `handle_pre_toot` で暗黙に横取りし、`#nowplaying 曲名` のキーワード検索・URL 補完・**サーバー側整形**まで一括で行っていた（`itunes_nowplaying` / `spotify_nowplaying` / `*_url_nowplaying` ハンドラ群）。これは「クライアントが構造化データを持たない」時代の道具立て。capsicum が OS から構造化メタデータを pull できる今、整形をサーバーに往復させる必要はなく、むしろサーバー側の正規化（`#nowplaying` 行に URL が無いと次行を詰める処理）がクライアント整形と干渉し、`#nowplaying` を末尾へ逃がす回避策が必要になった（#466）= 整形がサーバーにある弊害が顕在化した。

**帰結**:

- mulukhiya #4382 は「**テキスト整形器**」ではなく「**構造化メタデータ → 共有可能 URL を返す enrich プロキシ・エンドポイント**」へ再定義する。整形は capsicum が行うため、サーバーにテキスト整形を要求しない。
- 旧 nowplaying ハンドラ群（暗黙の pre-toot 横取り）は、URL 検索ロジックを上記 enrich エンドポイントへ移し、暗黙の投稿書き換えは段階的に廃止する方針（モロヘイヤ側で再設計）。capsicum 非利用クライアント（WebUI 等）への影響範囲はモロヘイヤ側で判断。
- capsicum 側: `formatNowPlayingFallback` を主整形器として配線済み（モロヘイヤ整形依存なし）。enrich エンドポイントが整ったら、URL を持たない源（MPRIS / SMTC / Apple Music）に対し任意で URL を補完する経路をオプション追加する。

## モデル（capsicum_core）

`packages/capsicum_core/lib/src/model/now_playing.dart`（新設）:

```dart
class NowPlayingInfo {
  final String? title;
  final String? artist;
  final String? album;
  final Uri? artworkUrl;     // MPRIS/SMTC は byte stream。投稿添付するかは UX 検討（下記）
  final String sourceAppName; // "Spotify" / "VLC" / "Rhythmbox" 等。表示・整形に使う
  final Uri? url;            // Spotify など URL を持つ源のみ。null なら整形パスへ
}
```

純 Dart モデルなので capsicum_core に置く（既存 `post.dart` / `user.dart` と同じ）。

## プラットフォーム実装方針

`lib/src/platform/now_playing/` に既存抽象と同じ構成（interface → factory → 実装、Riverpod の `Provider` で注入）で置く。ただし factory が返すのは **OS ネイティブ provider のみ**。Spotify provider と合成は `NowPlayingResolver` が担う。

| OS | OS ネイティブ pull | 実現手段 | 備考 |
|---|---|---|---|
| **Linux** | MPRIS（`org.mpris.MediaPlayer2.*`, D-Bus） | pub.dev `dbus`（**pure Dart**, 実績あり） | FFI 不要の見込み。Spotify Linux / VLC / Rhythmbox / Elisa 等 |
| **Windows** | SMTC（`GlobalSystemMediaTransportControlsSessionManager`） | **WinRT FFI**（`win32` パッケージ or 小さな C++ プラグイン） | **本マイルストーン最大の技術リスク。**良質な既存 Flutter プラグインが無い。先行スパイク推奨 |
| **macOS** | Apple Music のみ（要調査） | ミュージック.app scripting（ScriptingBridge / AppleScript） | **任意アプリ**の横断取得は公開 API で不可（private MediaRemote.framework は App Store 禁止）。ただし **Apple Music 限定なら scripting で pull 可能**（[#668](https://github.com/pooza/capsicum/issues/668)、サンドボックス entitlement 要検証）。push（Share Extension）も維持。Spotify は連携時のみ |
| **iOS** | Apple Music のみ | `MPMusicPlayerController.systemMusicPlayer.nowPlayingItem`（MediaPlayer framework、**公開 API**） | **Apple Music 限定なら公開 API で pull 可能**（[#668](https://github.com/pooza/capsicum/issues/668)、`NSAppleMusicUsageDescription` + メディアライブラリ許可）。任意アプリ横断は macOS と同じく不可。Share Extension（push）+ Spotify（pull）も併用 |
| **Android** | なし（v1.33 では入れない） | （将来 `NotificationListenerService`） | 他アプリの MediaSession 読み取りは通知アクセス権限が必要でプライバシー重め。share intent（push）+ Spotify（pull）に留める |

→ **OS ネイティブ pull の実装は実質 Linux(MPRIS) と Windows(SMTC) の 2 つだけ**。他 3 OS は Spotify(pull) + 共有(push) でカバーする。この割り切りで scope が締まる。

## 既存の共有（push）動線との統一

現状 [`compose_screen.dart`](../packages/capsicum/lib/src/ui/screen/compose_screen.dart) は共有テキストを `_controller.text = '#nowplaying ${sharedText}\n'` と **直挿入**している（`ShareIntentService.consumeSharedText()` 由来）。本設計の整形ロジック（`NowPlayingInfo` → 本文テキスト）を共有経路にも通し、push / pull で **整形を一本化**する（共有テキストに URL が含まれていればそのまま、無ければフォールバック整形）。これは小さなリファクタだが、フォーマットの二重管理を防ぐ。

## compose / 設定 UI

- **設定画面**: 「Spotify 連携」セクション（Annict 連携と同 UX）。詳細は [spotify-nowplaying-design.md](spotify-nowplaying-design.md)
- **compose 画面**: 既存の実況ボタン（`compose_screen.dart` の `Icons.live_tv`）の隣に「ナウプレを挿入」ボタン。表示条件と動作:
  - **表示**: `NowPlayingResolver` が「この端末で何か取れる可能性がある」= `spotifyEnabled && spotifyLinked` **または** OS ネイティブ provider が存在（Linux/Windows）
  - **押下**: `resolver.currentlyPlaying()` → `NowPlayingInfo` を整形して本文末尾に挿入。null なら SnackBar「現在再生中の曲がありません」。Spotify 401 なら「設定画面で Spotify と連携してください」+ 設定動線
- mulukhiya feature flag は既存 `MulukhiyaService.annictEnabled` と同じ場所（`detect()` の `features` パース）に `spotifyEnabled` / `spotifyLinked` を追加（[capsicum_backends/.../mulukhiya/service.dart](../packages/capsicum_backends/lib/src/mulukhiya/service.dart)）

## アートワーク

MPRIS / SMTC は artwork を byte stream で返せるが、**v1.33 では投稿添付しない**（テキストナウプレに集中）。`NowPlayingInfo.artworkUrl` はモデルに用意だけして、添付 UX は将来検討（over-reach を避ける）。

## 依存と着手順序

```
mulukhiya #4337 (Spotify user OAuth, OPEN/5.27.0) ──→ #570 Spotify（capsicum）
mulukhiya #4382 enrich プロキシ (URL 解決のみ, optional) ──→ #669 enrich 配線（URL なし源に共有 URL 補完）
                                                          └─ enrich 無しでも capsicum 整形で投稿は成立（必須ではない）
```

1. **先に固める（リードタイムが長い上流）**
   - mulukhiya #4337 の進捗確認（#570 の前提。OPEN / 5.27.0）
   - mulukhiya #4382 enrich プロキシは URL 補完（#669, optional）の前提だが**必須ではない**。整形ハンドラの起票は不要（§責務分担で撤回済み）
2. **capsicum 側の土台（上流非依存で着手可）**
   - `NowPlayingInfo` モデル + `NowPlayingProvider` interface + `NowPlayingResolver`（合成・優先順位）
   - capsicum 側フォールバック整形 + 共有(push)動線の整形統一
3. **源の実装**
   - Spotify provider（#570、mulukhiya #4337 デプロイ後）
   - Linux MPRIS provider（#466、`dbus` パッケージ）
   - Windows SMTC provider（#484、**先にスパイクで WinRT FFI の実現性を確認してから**本実装）
4. **検証**: 各 OS で OAuth 動線 + ナウプレ挿入を内部ベータ（TestFlight / Android internal / Linux AppImage / Windows MSIX）で pooza 検証（[[feedback_native_change_via_internal_beta]] / [[feedback_debug_vs_testflight]] の方針）

## 未確定・要判断（着手前に潰しておきたい点）

| # | 論点 | 暫定方針 |
|---|---|---|
| 1 | Windows SMTC を FFI 自前実装するか | まずスパイク。`win32` パッケージで WinRT `GlobalSystemMediaTransportControlsSessionManager` に到達できるか確認。困難なら小さな C++ プラグイン。SMTC が重ければ #484 を v1.33 内で後ろに置く / 再 on-hold も選択肢 |
| 2 | macOS / iOS / Android に OS ネイティブ pull を入れるか | **入れない**（公開 API で不可 / 権限重め）。Spotify(pull) + 共有(push) でカバー |
| 3 | MPRIS/SMTC 整形をモロヘイヤ必須にするか | 必須にしない。capsicum 側フォールバック整形を必ず持つ（モロヘイヤ未配備でも動く） |
| 4 | アートワーク添付 | v1.33 ではしない（モデルにフィールドだけ用意） |
| 5 | #570 が mulukhiya #4337 待ちで v1.33 内に間に合うか | 上流進捗次第。間に合わなければ Spotify を v1.33 内の後段に回し、MPRIS/フォールバックを先に出す判断もあり |

## 関連

- [spotify-nowplaying-design.md](spotify-nowplaying-design.md) — Spotify 取得源の詳細（本書の 1 ソース）
- 抽象パターンの先例: [desktop-plugin-compatibility.md](desktop-plugin-compatibility.md) / CLAUDE.md「デスクトップ対応」設計指針
- Issue: [#466](https://github.com/pooza/capsicum/issues/466) / [#484](https://github.com/pooza/capsicum/issues/484) / [#570](https://github.com/pooza/capsicum/issues/570)
