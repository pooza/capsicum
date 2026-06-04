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

文字情報しか無い源（MPRIS / SMTC）のための **整形パス**を 2 段で用意する:

1. **モロヘイヤ `text_nowplaying_formatter`（仮称）ハンドラ** — プリセットサーバーでは title/artist/album を渡して整形済みテキストを得る。**未起票**（#466 本文の宿題）。モロヘイヤ側はリードタイムがあるので **早めに capsicum-requirements 経由で起票**しておく
2. **capsicum 側フォールバック整形** — モロヘイヤ未配備サーバー / オフライン用に、最低限 `#nowplaying {title} / {artist}` を capsicum 内で組む。これが無いと「モロヘイヤありき」になり、#466 の制約（モロヘイヤ未配備でも動く）を満たせない

`NowPlayingInfo.url != null` なら URL 挿入、`null` なら整形パスへ、で分岐する。

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
| **macOS** | なし（pull は持たない） | — | 公開 API で他アプリの再生情報は取れない（private MediaRemote.framework は App Store 禁止）。**push（Share Extension）を維持**。pull ボタンは Spotify 連携時のみ動く |
| **iOS** | なし | — | macOS と同じ。Share Extension（push）+ Spotify（pull）のみ |
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
mulukhiya #4337 (Spotify user OAuth, OPEN/5.26.0) ──→ #570 Spotify（capsicum）
mulukhiya text_nowplaying_formatter (未起票・要起票) ──→ #466 MPRIS / #484 SMTC の整形（プリセット）
                                                          └─ capsicum 側フォールバック整形があれば未配備でも動く
```

1. **先に固める（リードタイムが長い上流）**
   - mulukhiya `text_nowplaying_formatter` 要件を起票（**まだ無い**。MPRIS/SMTC のプリセット整形に必須）
   - mulukhiya #4337 の進捗確認（#570 の前提。OPEN）
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
