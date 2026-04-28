# デスクトップ対応のプラグイン棚卸し

capsicum が依存している Flutter プラグインの macOS / Linux / Windows 対応状況まとめ。デスクトップ対応（[CLAUDE.md の長期構想](CLAUDE.md#長期構想-デスクトップ対応) を参照）を段階的に進めるための見積もり資料として使う。

対象のリポジトリ配下の [pubspec.yaml](../packages/capsicum/pubspec.yaml) および workspace 配下の各サブパッケージ（`capsicum_core` / `capsicum_backends` / `fediverse_objects`）の依存をベースに整理している。プラグイン構成が変わったら本書も更新すること。

## 分類基準

- **Tier A**: macOS / Linux / Windows すべて公式対応。そのまま使える
- **Tier B**: 対応はあるが制限や機能差があり、抽象層や代替プラグインでの吸収が必要
- **Tier C**: デスクトップ非対応またはブロッカー級。要抽象化・要置き換え

## Tier A: デスクトップ全対応

| プラグイン | 用途 | 備考 |
| --- | --- | --- |
| cupertino_icons | アイコンフォント | フォントアセットのみ |
| flutter_riverpod | 状態管理 | pure Dart |
| go_router | ルーティング | pure Dart |
| shared_preferences | 軽量永続化 | 全プラットフォーム公式対応 |
| dio | HTTP クライアント | pure Dart |
| url_launcher | URL 起動 | 全プラットフォーム公式対応 |
| path_provider | パス取得 | 全プラットフォーム公式対応 |
| package_info_plus | アプリ情報 | 全プラットフォーム公式対応 |
| sentry_flutter | エラー収集 | 全プラットフォーム公式対応 |
| scrollable_positioned_list | 位置指定スクロール | pure Dart ウィジェット |
| yaml / html_unescape | パーサ | pure Dart |
| web_socket_channel / http_parser / uuid / json_annotation | sub-package 依存 | pure Dart |

## Tier B: 制限あり・代替ありだが対応可能

| プラグイン | 用途 | 問題 | 対応案 |
| --- | --- | --- | --- |
| flutter_secure_storage | 機密情報保存 | Linux は `libsecret-1-dev` の導入が前提。Flatpak では manifest への依存宣言が必要 | そのまま使用、Flathub ビルド時に finish-args / dependencies を記述 |
| flutter_local_notifications | ローカル通知 | macOS / Linux / Windows 対応済みだが機能差あり。Linux は libnotify、Windows は Toast XML。アクションボタン等はプラットフォーム依存 | 通知サブシステム抽象化層を介して機能差を吸収 |
| flutter_web_auth_2 | OAuth 認証 | モバイルはカスタムスキーム、デスクトップは localhost コールバック経由。Linux/Windows でも動作するが挙動差あり。Android エミュレータ不安定の既知問題（[tech-notes.md](tech-notes.md) の認証フロー節を参照） | そのまま使用。デスクトップ実機での動作確認は必須 |
| image_picker | 画像選択 | iOS/Android/macOS は対応、**Linux/Windows は未対応** | デスクトップは `file_selector` に置き換え。抽象層（例: `MediaPicker`）で使い分け |

## Tier C: 要抽象化・要置き換え（ブロッカー）

| プラグイン | 用途 | 問題 | 対応案 |
| --- | --- | --- | --- |
| ~~workmanager~~ | ~~バックグラウンドポーリング~~ | v1.19 (#348) で撤去済み。通知リレー（#52）への完全移行に伴いモバイル側も不要になった | デスクトップ対応でバックグラウンド相当の仕組みが要る場合は `BackgroundTaskScheduler` 抽象層（#328）の実装として Dart `Timer` + 常駐で組む |
| **video_player** | 動画再生 | macOS は公式対応（v1.21 TestFlight Internal で再生・添付・投稿の動作を確認済み）。**Linux / Windows は非対応** | Linux / Windows 着手時に各プラットフォーム対応を再評価し、必要に応じて `media_kit` へ置き換える。事前調査は本書 §2 に保存済み |

## 影響度の大きい順と対応タイミング

### 1. BackgroundTaskScheduler 抽象化（第2段階で対応）

モバイル側の workmanager 依存は v1.19 (#348) で撤去済み。プッシュ通知は APNs / FCM リレー ([#52](https://github.com/pooza/capsicum/issues/52)) に一本化されており、モバイルでバックグラウンドポーリングを復活させる予定はない。

ただしデスクトップは push 受信経路がないため、[#328](https://github.com/pooza/capsicum/issues/328) の `BackgroundTaskScheduler` 抽象層を第2段階で導入し、デスクトップ実装としては Dart `Timer` + アプリ常駐前提の軽量ポーリングを入れる。モバイル側は抽象層の no-op 実装で十分。

### 2. video_player → media_kit 移行（保留: Linux / Windows 着手時に再判断）

[#306](https://github.com/pooza/capsicum/issues/306) の事前調査結果。**結論: 移行可能だが緊急性は低い**。影響範囲は媒体ビューワー 1 ファイルに収まり、API 置き換えのみで対応できる。実装は [Linux / Windows 対応着手時（v1.24 想定）](CLAUDE.md#長期構想-デスクトップ対応) に当該プラットフォームでの video_player 対応状況を改めて棚卸し、必要があれば実施する。

#### 使用範囲

| ファイル | 用途 | 内訳 |
| --- | --- | --- |
| [packages/capsicum/lib/src/ui/screen/media_viewer_screen.dart](../packages/capsicum/lib/src/ui/screen/media_viewer_screen.dart) | 添付メディアの全画面ビューワー | `_VideoPage`（動画 + `gifv`）と `_AudioPage`（音声）の 2 controller。どちらも `VideoPlayerController.networkUrl` を使う |

`Image.network` / `CachedNetworkImage` 系で表示する画像（`AttachmentType.image`、通常 GIF 含む）は対象外。`gifv` だけが video 経路に流れる。

#### 候補プラグイン: media_kit

| 項目 | 値 |
| --- | --- |
| バージョン | `media_kit: ^1.2.6`（pub.dev、MIT、検証済みパブリッシャー） |
| ベース | libmpv の FFI バインディング |
| 対応プラットフォーム | Android / iOS / macOS / Windows / GNU/Linux / Web の 6 種 |
| 必要な周辺パッケージ | `media_kit_video: ^2.0.1` + `media_kit_libs_video: ^1.0.7`（**video libs は libmpv フル機能を含むため音声も再生可能**。capsicum は動画 + 音声両用なので video libs 1 本で足りる。video / audio の libs は混在不可） |

#### API 置き換え対応

| 現行（video_player 2.x） | 置き換え（media_kit 1.x） |
| --- | --- |
| `VideoPlayerController.networkUrl(uri)` | `Player()..open(Media(uri.toString()))` |
| `controller.initialize()` | `await player.open(...)`（`Future` で完結） |
| `controller.play()` / `pause()` | `player.play()` / `player.pause()` |
| `controller.addListener(cb)` | `player.stream.playing.listen(cb)` 等の Stream API |
| `controller.value.isPlaying` / `position` / `duration` | `player.state.playing` / `position` / `duration` |
| `controller.value.aspectRatio` | `player.state.width` / `height` から算出 |
| `VideoPlayer(controller)` | `Video(controller: VideoController(player))` |
| `VideoProgressIndicator` | 標準ウィジェットで自前実装（`Slider` + `state.position` ストリーム） |

State 管理がリスナー方式から Stream 方式に変わるため、現状の `setState` 都度更新は `StreamBuilder` ベースに書き換える。

#### プラットフォーム別の影響

| プラットフォーム | バンドル影響 | ビルド設定 |
| --- | --- | --- |
| iOS | `media_kit_libs_ios_video` が CocoaPods 経由で libmpv を取り込み | App Store 提出は問題なしと公式案内あり |
| Android | `media_kit_libs_android_video` を AAR で取り込み | 特別設定不要 |
| macOS | バンドル増 +12〜15 MB（libmpv） | CocoaPods 経由 |
| Windows | バンドル増 +20〜30 MB（`libmpv-2.dll` 同梱） | MSIX パッケージング時に DLL 同梱を確認 |
| Linux | libmpv 依存。Flatpak の `finish-args` / dependencies に追記必要 | AppImage は同梱、配布形態ごとに調整 |
| Web | HTML5 video 経路、別実装 | 当面 capsicum の対象外 |

#### 失う機能 / 得る機能

- **失う機能なし**: 現在 `media_viewer_screen.dart` で使っている API（再生位置・aspectRatio・seek・controls）は media_kit ですべて代替可能
- **得る機能**: HEVC / AV1 / VP9 など多コーデック対応、HW アクセラレーション（VideoToolbox / MediaCodec / VAAPI / D3D11VA）、HLS / DASH ストリーミング、字幕・フィルタ等。capsicum の現用途では大半が不要だが、将来的なライブ配信・長尺動画への布石になる

#### モバイルへの影響

iOS / Android は media_kit 側がモバイル対応しているため動作自体は問題なし。ただし native ライブラリ（libmpv）が増えるためアプリサイズが増加する。実機での再生挙動（HW デコード切替・音声出力ルーティング）は移行時に確認が必要だが、置き換え自体のブロッカーにはならない。

#### 実施タイミングと優先度

- v1.21 の TestFlight Internal 検証で macOS 上の video_player は再生・添付・投稿いずれも問題なく動作することを確認済み（pooza が動画つき投稿で意図的に検証）。これにより v1.24 必須スコープからは外し、**Linux / Windows 対応着手時に再評価して必要なら移行**する位置付けにする
- 当面は現行 video_player のまま運用（macOS / iOS / Android は既にカバー済み）
- 上記の API 置き換え対応・プラットフォーム別影響・失う/得る機能の調査結果は、移行決定時にそのまま実装の手引きとして使える状態を保つ

### 3. image_picker ↔ file_selector 抽象化（第2段階）

第2段階で `BackgroundTaskScheduler` と同時に `MediaPicker` 抽象化を入れる。変更量は比較的小さく、デスクトップ対応の最初のネイティブ機能体験（ファイル選択）に直結するため投資対効果が高い。

### 4. flutter_local_notifications の機能差吸収（第2段階）

通知モデル再設計の一部として、抽象化層で機能差を吸収する。アクションボタンの有無など、プラットフォーム差を UI 層に漏らさない設計が必要。

## その他の観点

- **image_picker_macos**: 本体経由で自動的に動くが、内部実装は `file_selector` 相当。UX が iOS とやや異なる
- **flutter_local_notifications の Windows 実装**: Windows 10/11 の Toast 通知を使う。MSIX パッケージングが必須で、素の exe 配布だと通知が出ない。Microsoft Store 経由推奨の根拠のひとつ
- **Linux で Flathub 配布する場合のサンドボックス制約**: secure_storage / notifications / file access 等、必要な権限（finish-args）を manifest に明示する必要がある

## 更新時の注意

- pubspec.yaml の変更と同期して本書を更新する
- 新しくプラグインを追加する際は、本書の Tier A/B/C にあらかじめ分類してから採用を判断する
- Tier C のプラグインを追加する場合は、抽象層の設計コストを計上したうえで検討する
