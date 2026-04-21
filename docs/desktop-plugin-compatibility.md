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
| **video_player** | 動画再生 | macOS は公式対応だが、**Linux / Windows は非対応** | `media_kit` への置き換えを検討。libmpv ベースで全プラットフォーム対応。影響範囲が大きいため事前調査が必要 |

## 影響度の大きい順と対応タイミング

### 1. BackgroundTaskScheduler 抽象化（第2段階で対応）

モバイル側の workmanager 依存は v1.19 (#348) で撤去済み。プッシュ通知は APNs / FCM リレー ([#52](https://github.com/pooza/capsicum/issues/52)) に一本化されており、モバイルでバックグラウンドポーリングを復活させる予定はない。

ただしデスクトップは push 受信経路がないため、[#328](https://github.com/pooza/capsicum/issues/328) の `BackgroundTaskScheduler` 抽象層を第2段階で導入し、デスクトップ実装としては Dart `Timer` + アプリ常駐前提の軽量ポーリングを入れる。モバイル側は抽象層の no-op 実装で十分。

### 2. video_player → media_kit 移行

最も影響範囲が大きい置き換え候補。以下の調査が必要:

- capsicum 内で `video_player` を使っている箇所の特定
- 動画添付・GIF 再生・プレビュー等のユースケース洗い出し
- `media_kit` 移行で失われる機能 / 新たに得る機能の比較
- iOS/Android 側への影響確認（`media_kit` はモバイルも対応するが挙動差あり）

これはデスクトップ対応の前提というより、デスクトップ対応の**コスト**として計上しておく必要がある。事前調査だけ先に済ませておけば、本格着手時の見積もり精度が上がる。

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
