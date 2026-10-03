# デスクトップ展開の経緯 — 決着済みの記録

⚠⚠ **3 段階とも完了し、5 プラットフォームすべて出荷済み。**現役の設計指針・配送の注意は [CLAUDE.md](../CLAUDE.md)「デスクトップ対応」に残してある。ここは**なぜこの形になったか**を辿るための記録（#1184 で 2026-09-30 に退避）。

| 段階 | 版 | 中身 |
| --- | --- | --- |
| 第 1 | v1.21 | macOS ネイティブ化（土台） |
| 第 2 | v1.23 | バックグラウンド / 通知モデルの再設計 |
| 第 3 | v1.24〜v1.27 | Linux AppImage / Windows Microsoft Store |

⚠ **各マイルストーンの主題・個別 Issue 構成は [GitHub Milestones](https://github.com/pooza/capsicum/milestones) が正本**で、ここには複写しない。版ごとの消化 Issue は [archive/release-log.md](release-log.md)。

## デスクトップ対応

macOS / Linux / Windows のデスクトップ環境への展開。動機は、iOS 版を Mac 上で実況用途に使って手応えがあること。v1.21 以降のマイルストーンに組み込み済み（当初は v1.19 → v1.20 → v1.21 と後ろ倒しを重ね、プッシュ通知完成 v1.20 を挟んだ上で着手する並びに落ち着いた）。

1. **第1段階: macOS ネイティブ化（v1.21、土台完成）** — `flutter config --enable-macos-desktop` を有効化し、Apple Developer Team / Apple Development 署名 / App Sandbox / Hardened Runtime / keychain-access-groups の設定を導入。Universal Purchase で iOS と同一 App レコードに紐付け済み。プラグインのデスクトップ対応状況の棚卸し・video_player → media_kit の事前調査もこの段階で完了。ストア配布（.pkg ラップ + fastlane の macOS lane）は [#407](https://github.com/pooza/capsicum/issues/407) で対応済み
2. **第2段階: バックグラウンド/通知モデルの再設計（v1.23、完了）** — デスクトップにはバックグラウンド更新の概念がないため、通知ポーリング相当の仕組みを抽象化して差し替え可能にした。v1.18 のプッシュ通知リレー完了・v1.19 (#348) での workmanager / iOS BGTask 撤去後、モバイル側は APNs / FCM 一本化済み。v1.23 で `BackgroundTaskScheduler`（#328、Dart `Timer` + 常駐前提のフォールバック実装）/ `MediaPicker`（#329、image_picker + file_selector 統合）/ `NotificationSubsystem`（#330、flutter_local_notifications プラットフォーム差吸収）の各層を導入
3. **第3段階: Linux / Windows 対応（v1.24〜v1.27、完了）** — 第2段階で通知周りが整理され、プラグイン依存の棚卸しが済んでから着手。Linux は **AppImage 単独配布**（v1.24〜。Flathub は [#604](https://github.com/pooza/capsicum/issues/604) で 2026-05-29 断念、以降は AppImage 単独に確定）。Windows は v1.25 で **自己署名 MSIX 直配**（[#423](https://github.com/pooza/capsicum/issues/423)）、v1.27 で **Microsoft Store 公開達成**（[#544](https://github.com/pooza/capsicum/issues/544)、毎リリース Partner Center Web UI から手動 publish）。OAuth は 3 OS とも `flutter_web_auth_2` の localhost callback（port 7099、[`AppConstants.localhostOAuthPort`](../../packages/capsicum/lib/src/constants.dart)）に統一。動画再生は media_kit 移行（[#492](https://github.com/pooza/capsicum/issues/492)、v1.30）で Linux / Windows も対応。コード署名証明書取得（[#534](https://github.com/pooza/capsicum/issues/534)）は Store 再署名のため当面不要（IV 証明書取得済みだが capsicum 適用はお蔵入りで close）。Windows push 本配線（[#474](https://github.com/pooza/capsicum/issues/474)）は **v1.40（「Windows 仕上げ」大更新マイルストーン）で出荷済み**（WNS 資格情報の満了は 2028-06-22）。Windows 投げ銭 IAP（[#599](https://github.com/pooza/capsicum/issues/599)）は当初 v1.40 に束ねる想定だったが、x64 実機環境・Partner Center アドオン審査待ちで分離し **v1.43 で出荷済み**（Microsoft Store IAP）。SMTC NowPlaying（[#484](https://github.com/pooza/capsicum/issues/484)）は v1.33 で実装・**実機検証済み**（C++/WinRT メソッドチャンネル。ARM64 Windows でローカル x64 ビルドは ATL 未導入 / jni / crashpad の x64-on-ARM64 で詰まるため、CI windows-release.yml の `capsicum-msix` artifact を gh run download → `Add-AppxPackage` で導入して検証する経路を確立）。実機検証は Linux [#425](https://github.com/pooza/capsicum/issues/425) / macOS [#494](https://github.com/pooza/capsicum/issues/494)。

各マイルストーンの主題・スコープ・個別 Issue 構成は [GitHub Milestones](https://github.com/pooza/capsicum/milestones) が正本（CLAUDE.md には複写しない）。過去の版ごとの主題・消化 Issue・分割の経緯は [archive/release-log.md](release-log.md) と Milestones を参照する。スコープの組み方・過積載時の調整・移行整備の判断規約は「[Issue 管理 › マイルストーン運用](#マイルストーン運用)」節と [milestone-transition.md](../milestone-transition.md) を正本とする（**大更新は独立配置**が基本方針）。

Issue [#475](https://github.com/pooza/capsicum/issues/475) (Linux push 方針) の議論で、**desktop 3 OS 共通の「WebSocket streaming → OS ローカル通知」設計** を確定した（2026-05-15、[desktop-notification-design.md](desktop-notification-design.md)）。Mastodon の `user` stream / Misskey の `main` channel に長寿命 WebSocket で接続し、notification / announcement event を `flutter_local_notifications` (libnotify / NSUserNotification / WinRT Toast) に流す経路。アプリ起動中の中間解として 3 OS 共通で機能し、native push（[#468](https://github.com/pooza/capsicum/issues/468) macOS APNs=v1.34 / [#474](https://github.com/pooza/capsicum/issues/474) Windows WNS=v1.40、いずれも実装済み）とは `notification.id` dedup で併存する。実装 issue は [#569](https://github.com/pooza/capsicum/issues/569) として切り出し済み（v1.34 主役、大更新）。本設計の確定により、ポーリング前提だった「お知らせ通知 A 案」(#476) は不要となり close、capsicum-relay 経由の C 案 (#477、v1.29) は mobile 配信を継続して担う構図に整理された。この配送対象は v1.57 で **mobile + macOS + Windows** に広がった（macOS = [#919](https://github.com/pooza/capsicum/issues/919) / capsicum-relay#36 Phase 1、Windows = [#978](https://github.com/pooza/capsicum/issues/978) / relay#36 Phase 2。relay 側はいずれも本番へデプロイ済み）。**Linux だけはネイティブ push の経路自体が無い**ため、お知らせは**アプリ起動中しか届かない**。設定画面はトグルの代わりにその旨を説明する。

配送先を増やすときは **relay の `AnnouncementWorker#deliver` の `case` と capsicum の `deliverableDeviceTypes` が 1 対 1** であること（片方だけ広げると「購読行はあるのに届かない」／「送っても黙って捨てられる」になる）に加え、**payload に載せるフィールドの device_type 差**にも注意する。Windows 宛だけは `announcement_body`（整形済み本文）を足し `announcement_content`（HTML）を落とす — WNS raw の上限 5000B に対して HTML は表示に使われないため。⚠ **この整形本文を全 device_type 共通の payload に足してはいけない**: APNs / FCM は 4KB 上限で、お知らせの payload には degrade で落とせるキーが無く（`ApnsPayload::ENCRYPTED_KEYS` は暗号化 Web Push 由来のキーのみ）、`poll_server` が配送後に `mark_announcement_seen` を打つため **1 通が永久に失われる**（relay PR #43 の Codex P1）。

動機の具体例:

- iOS アプリを Mac で動かす (Designed for iPad) モードだとファイル選択が iOS のドキュメントピッカーになり、Mac のネイティブな Finder ベースの選択ができない。画像・動画添付が実況用途で地味に手間。macOS ネイティブビルドなら `file_selector` / `image_picker` の macOS 実装が NSOpenPanel を出してくれる
- キーボードショートカット・ウィンドウ管理・通知センター連携など、デスクトップ固有の体験も macOS ネイティブなら自然に組める

設計指針（分岐を最小化するためのルール）:

- **UI の分岐軸はプラットフォームではなく画面幅**にする。`Platform.isXxx` は UI 層に基本入れない。iPad で画面が広ければデスクトップと同じレイアウトになるべきだし、デスクトップでウィンドウを狭めたらモバイル風になるべき。Responsive design の単一軸に集約する
- **プラットフォーム固有機能は必ず抽象層を経由**させる。`flutter_local_notifications` を直接呼ばず、`BackgroundTaskScheduler` のようなインターフェースを挟む。第2段階（通知モデル再設計）の主題と噛み合う
- **プラットフォーム定数はテーブル化**。ショートカット・メニュー構成などは1箇所にまとめ、プラットフォームごとにテーブルを差し替える
- **条件付きコンパイル（conditional import）は最後の手段**。使う場合も `lib/src/platform/` のような特定ディレクトリに閉じ込める

配布・ストア・ツールチェーンの方針（macOS は Apple Developer Program を iOS と共用、Linux は AppImage 単独（Flathub は 2026-05-29 断念 [#604](https://github.com/pooza/capsicum/issues/604)）、Snap は不採用、Windows は v1.25 で GitHub Releases 経由の自己署名 MSIX 直配を再開し v1.27 で Microsoft Store 公開を達成 ([#544](https://github.com/pooza/capsicum/issues/544)、2026-05-20 審査通過)。自己署名直配は v1.43（[#760](https://github.com/pooza/capsicum/issues/760)）で廃止し、以降は Store 単独）、および段階的な実装順序は [release-pipeline.md](release-pipeline.md) を参照。プラグインのデスクトップ対応状況の棚卸しは [desktop-plugin-compatibility.md](../desktop-plugin-compatibility.md) にまとめている。第2段階では `BackgroundTaskScheduler`（[#328](https://github.com/pooza/capsicum/issues/328)）/ `MediaPicker`（[#329](https://github.com/pooza/capsicum/issues/329)）/ 通知サブシステム（[#330](https://github.com/pooza/capsicum/issues/330)）を抽象化した。

macOS の付加機能として、Music.app 等の「共有」メニューから capsicum に投稿を流す Share Extension（[#422](https://github.com/pooza/capsicum/issues/422)）を **v1.24 で同梱済み**。iOS の Share Extension と同パターンで App Group コンテナ経由、共有元（Music.app 等）が渡す URL・テキストをそのまま compose に流し込む。なお NowPlaying の整形そのものは、v1.33 の責務分担見直しで**クライアント（capsicum）側に確定**しており（[nowplaying-design.md](nowplaying-design.md) §責務分担）、モロヘイヤ側に残すのは URL を持たない源向けの enrich（メタデータ → 共有 URL 解決、[mulukhiya #4382](https://github.com/pooza/mulukhiya-toot-proxy/issues/4382)）のみ。旧来の「サーバー側ハンドラへ整形委譲」は廃止方針。

## Linux 固有の差分（v1.24）

v1.24 リリース直前の Linux 実機検証で判明・対応した、他プラットフォームと挙動が違う部分の **一覧**。各項目の詳細な理由・手順は二重管理を避けるため正本（コード doc コメント / distribution 配下）に集約し、ここでは差分の存在と参照先だけを示す（#509）。

- **OAuth 経路はシステムブラウザ + localhost callback** — 正本は [`AppConstants.localhostOAuthPort`](../../packages/capsicum/lib/src/constants.dart)（ポート 7099 固定の理由・3 OS 共通の背景を記載）。Linux / Windows / macOS いずれも `flutter_web_auth_2` の server impl で回避する。
- **AppImage の起動時観測性**（`crashpad_handler` の chmod 補正 / `AppRun` logging wrapper）— 正本は [distribution/linux/appimage/README.md](../../distribution/linux/appimage/README.md) と [`build.sh`](../../distribution/linux/appimage/build.sh)。
- **sentry-native database path 固定** — 正本は [`platform/paths.dart`](../../packages/capsicum/lib/src/platform/paths.dart) の `resolveSentryNativeDatabasePath`（AppRun の XDG 解決との対応も記載）。
- **flutter_secure_storage の register race 対策** — 正本は [`account_storage.dart`](../../packages/capsicum/lib/src/service/account_storage.dart) の `_readWithRegisterRetry`（短間隔 retry の理由を記載）。

背景 issue は #488 / #489 / #491 / #496、プラグイン対応状況は [desktop-plugin-compatibility.md](../desktop-plugin-compatibility.md) の flutter_web_auth_2 行を参照。

制約: モロヘイヤ透過プロキシ前提のためネットワーク層は問題にならない。

