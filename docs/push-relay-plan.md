# プッシュ通知リレー計画書

## 背景

capsicum の iOS 通知は workmanager による BGTaskScheduler ポーリング方式だが、v1.15.0 の観測性強化（#293）により、**発火回数 0回・全く動作していない**ことが確認された。同一端末の Mastodon / Misskey PWA は正常に通知が届いており、ポーリングの改善では根本的に解決できない。

iOS でプッシュ通知を提供する Fediverse クライアント（Toot!、Ice Cubes、Ivory、Mona 等）はいずれも独自のリレーサーバーを運営しており、capsicum も同様のアプローチを取る。

## 全体アーキテクチャ

```
┌──────────────┐    Web Push     ┌──────────────┐    APNs/FCM    ┌──────────────┐
│  Mastodon /  │ ──────────────→ │   リレー     │ ─────────────→ │  capsicum    │
│  Misskey     │    (VAPID)      │   サーバー   │                │  (iOS/Android)│
└──────────────┘                 └──────────────┘                └──────────────┘
```

### 通信フロー

1. capsicum が APNs デバイストークンを取得（iOS ネイティブ層）
2. capsicum がリレーサーバーにデバイストークン + アカウント情報を登録
3. capsicum が Mastodon / Misskey にリレーサーバーの受信エンドポイントを Web Push 購読先として登録
4. Mastodon / Misskey が通知発生時にリレーサーバーへ Web Push 送信
5. リレーサーバーが Web Push ペイロードを APNs / FCM に変換して転送
6. capsicum が通知を受信・表示

### サブスクリプション登録の SNS 差異

| | Mastodon | Misskey |
|---|---|---|
| 登録 API | `POST /api/v1/push/subscription` | `POST /api/sw/register` |
| パラメータ | endpoint, keys (p256dh, auth) | endpoint, publickey, auth |
| VAPID 公開鍵取得 | `GET /api/v1/instance` | `POST /api/meta` → `swPublickey` |
| プッシュプロトコル | Web Push (VAPID) | Web Push (VAPID) |

リレーサーバーの受信側は共通。クライアント側の adapter で登録 API を切り替える。

## 既存 OSS リレー実装の評価

### mastodon/webpush-apn-relay（Rust）

- Mastodon 公式が提供する Web Push → APNs リレー
- 評価ポイント:
  - [ ] Misskey の Web Push ペイロードとの互換性（Mastodon 固有の前提がハードコードされていないか）
  - [ ] FCM 対応の有無（APNs のみの場合、Android 向けに拡張が必要）
  - [ ] デプロイ・運用の容易さ
  - [ ] メンテナンス状況

### Ice Cubes リレー（公開 OSS）

- Ice Cubes 開発者が公開しているリレー実装
- 評価ポイント:
  - [ ] 実装言語・アーキテクチャ
  - [ ] Misskey 互換性
  - [ ] 参考にできる設計パターン

### 評価結果に基づく判断

- 既存 OSS をそのまま利用可能 → デプロイして使う
- Mastodon 固有のハードコードあり → フォークして Misskey 対応を追加
- どちらも不適 → 自前実装（既存 OSS を参考に）

## インフラ設計

### リレーサーバー

- **専用の小規模サーバーを新設**する（#52 の方針通り。既存サーバーとの同居はしない）
- 規模に応じてプランを段階的に引き上げる
- ホスティング先・OS・ランタイムは OSS 評価後に決定

### 必要なクレデンシャル

| 項目 | 用途 |
|---|---|
| APNs 認証キー（.p8）| iOS プッシュ通知送信 |
| Firebase サービスアカウント | Android プッシュ通知送信（FCM） |
| VAPID 鍵ペア | Web Push サブスクリプション用（リレーサーバーが生成） |

### Apple Developer Program

iOS の APNs 利用には Apple Developer Program のプッシュ通知 capability が必要。capsicum は既に Program に登録済みなので、Xcode で Push Notifications capability を追加し、APNs 認証キーを Apple Developer ポータルから発行する。

## capsicum 側の実装範囲

### Swift ネイティブ層（iOS）

AppDelegate.swift に APNs 関連のコードを追加する必要がある:

- `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` — デバイストークン取得
- `application(_:didFailToRegisterForRemoteNotificationsWithError:)` — 登録失敗ハンドリング
- `UNUserNotificationCenter` の設定

**注意**: v1.15 開発時に AppDelegate.swift の変更で起動不能になった経緯あり（コミット未記録）。Flutter エンジン初期化・プラグイン登録との順序に注意して段階的に進める。原因の特定と再現が最初のステップ。

### Dart 側

- `PushNotificationService` — リレーサーバーとの通信（登録・解除・トークン更新）
- `BackendAdapter` 拡張 — Mastodon / Misskey それぞれの Web Push サブスクリプション登録
  - `MastodonAdapter`: `POST /api/v1/push/subscription`
  - `MisskeyAdapter`: `POST /api/sw/register`
- `PushSubscriptionSupport` mixin（Feature インターフェース）の新設
- 既存の workmanager ポーリングとの共存（リレー未対応サーバー向けフォールバック）

### Android 側

- Firebase Cloud Messaging の設定（`google-services.json`）
- FCM トークンの取得と FlutterFire 経由の連携
- `AndroidManifest.xml` への通知チャンネル設定

## 段階的リリース計画

### Stage 1: Mastodon プッシュ通知（プリセットサーバー）

**対象マイルストーン**: v1.18（仮）

1. OSS リレー実装の評価・選定
2. リレーサーバーのデプロイ・動作確認
3. iOS: AppDelegate.swift の APNs 対応（起動不能問題の解決を含む）
4. Android: FCM セットアップ
5. capsicum: MastodonAdapter に Web Push サブスクリプション登録を実装
6. capsicum: リレーサーバーへのデバイストークン登録
7. capsicum: 通知受信・表示
8. プリセットサーバー（美食丼・デルムリン丼・キュアスタ！）で動作確認

### Stage 2: Misskey プッシュ通知

1. MisskeyAdapter に `sw/register` による Web Push サブスクリプション登録を実装
2. リレーサーバーの Misskey ペイロード互換性を確認（必要ならフォーク対応）
3. ダイスキーで動作確認

### Stage 3: 外部ユーザー向け有償提供

- 外部ユーザーの一定規模が確認されてから具体化
- 課金手段（IAP / 外部決済）・料金体系・判定ロジックの設計
- capsicum のマイルストーンとは別プロジェクトとして扱う

## 課金方針

| 対象 | 料金 |
|---|---|
| プリセットサーバーのユーザー | 無償 |
| 外部ユーザー | 有償（Stage 3 で具体化） |

判定はアカウントの所属サーバーで行う（プリセットリスト照合）。

## 未決事項

- [ ] OSS リレー実装の詳細評価（Misskey 互換性・FCM 対応）
- [ ] リレーサーバーのホスティング先選定
- [ ] v1.15 で発生した Swift ネイティブ層の起動不能問題の原因特定
- [ ] 美食丼のプリセット扱い（#52 コメント参照）
- [ ] workmanager ポーリングの扱い（リレー導入後も残すか）

## 関連 Issue・ドキュメント

- [#52](https://github.com/pooza/capsicum/issues/52) — プッシュ通知リレー（本体 Issue）
- [#293](https://github.com/pooza/capsicum/issues/293) — iOS 通知の観測性強化（観測結果: 発火 0回）
- [CLAUDE.md プッシュ通知セクション](CLAUDE.md#プッシュ通知)
- [release-pipeline.md](release-pipeline.md)
