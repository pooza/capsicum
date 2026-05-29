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

### mastodon/webpush-apn-relay（Go、約250行）

- Mastodon 公式（元は Toot! 作者）が提供する Web Push → APNs リレー
- **Misskey 互換性: 低い** — `Content-Encoding: aesgcm` のみ対応。Misskey が使う `aes128gcm`（RFC 8291）は未対応（コード上コメントアウト状態）
- **FCM 対応: なし** — APNs 専用設計
- **ペイロード形式が Toot! 固有** — z85 エンコードの独自フォーマット。受信アプリ側も合わせる必要あり
- **メンテナンス**: 低頻度（最終コミット 2025-03）
- **運用**: P12 証明書 + 環境変数で起動可能。Docker / Fly.io 対応

### Ice Cubes リレー

- **ソースコード非公開**。Fly.io 上で運用（`icecubesrelay.fly.dev`）
- ベースは上記の webpush-apn-relay と推定

### 評価結論

**既存 OSS をそのまま使うのは困難**。理由:

1. `aes128gcm` 未対応（Misskey に必要）
2. FCM 未対応（Android に必要）
3. ペイロード形式が Toot! 固有

→ **Ruby で自前実装する**。既存 OSS（特に webpush-apn-relay の通信フロー）は参考にしつつ、capsicum の要件（Mastodon + Misskey、APNs + FCM）に最適化した設計で新規に書く。Ruby を選択する理由は、モロヘイヤの運用・デバッグ知見がそのまま使えること、この規模では性能差が問題にならないこと。

## インフラ設計

### リレーサーバー

- **専用の小規模サーバーを新設**する（#52 の方針通り。既存サーバーとの同居はしない）
- **ホスティング: Linode Nanode**（$5/月、1 vCPU / 1GB RAM / 25GB SSD）— **構築済み**
- 既存サーバー群と同じ VPS 運用の延長で管理できる
- 規模に応じてプランを段階的に引き上げる
- 構成: Ruby + systemd + SQLite（デバイストークン永続化）

| 項目 | 値 |
|------|-----|
| ホスト名 | flauros.b-shock.co.jp |
| 公開ドメイン | relay.capsicum.shrieker.net |
| OS | Ubuntu 24.04 LTS |
| SSH | `deploy@flauros.b-shock.co.jp` |
| スペック | 1 vCPU / 1GB RAM / 25GB SSD |

### リレーサーバーの箇条設計

- **エンドポイント**:
  - `POST /register` — デバイストークン + アカウント情報の登録（capsicum → リレー）
  - `DELETE /register/:id` — 登録解除
  - `POST /push/:token` — Web Push 受信エンドポイント（Mastodon / Misskey → リレー）
  - `GET /health` — ヘルスチェック
- **Web Push 受信フロー**:
  1. Mastodon / Misskey から Web Push を受信（`aesgcm` / `aes128gcm` 両対応）
  2. ペイロードはそのまま（復号せず）APNs / FCM に転送。復号はクライアント側で行う
  3. 転送先はトークンに紐づくデバイス種別（iOS / Android）で振り分け
- **永続化**: SQLite に登録情報を保存（token, device_type, account, server, created_at）
- **認証**: capsicum からの登録リクエストはアプリ固有の shared secret で検証
- **デプロイ**: systemd で常駐。リバースプロキシ（nginx）で HTTPS 終端
- **監視**: ヘルスチェックエンドポイント + Sentry（エラー通知）

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

### Android 側

- Firebase Cloud Messaging の設定（`google-services.json`）
- FCM トークンの取得と FlutterFire 経由の連携
- `AndroidManifest.xml` への通知チャンネル設定

## 段階的リリース計画

### Stage 1: Mastodon プッシュ通知（プリセットサーバー）

**対象マイルストーン**: v1.18。リレーサーバーの実装は v1.16 と並行して進める（別リポジトリ・別インフラのため干渉なし）。iOS APNs 対応（#314）は v1.16 に前倒し済み。

1. OSS リレー実装の評価・選定
2. リレーサーバーのデプロイ・動作確認
3. iOS: AppDelegate.swift の APNs 対応（起動不能問題の解決を含む）
4. Android: FCM セットアップ
5. capsicum: MastodonAdapter に Web Push サブスクリプション登録を実装
6. capsicum: リレーサーバーへのデバイストークン登録
7. capsicum: 通知受信・表示
8. プリセットサーバー（美食丼・デルムリン丼・キュアスタ！）で動作確認

Stage 1 の動作確認対象は Mastodon のプリセットサーバー。きゅあすきー・ダイスキー（Misskey）は Stage 2 で確認する。

### Stage 2: Misskey プッシュ通知

1. MisskeyAdapter に `sw/register` による Web Push サブスクリプション登録を実装
2. リレーサーバーの Misskey ペイロード互換性を確認（必要ならフォーク対応）
3. きゅあすきー・ダイスキーで動作確認

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

## 決定済み事項

- [x] OSS リレー実装の評価 → 既存 OSS は不適。Ruby で自前実装
- [x] リレーサーバーのホスティング先 → Linode Nanode（$5/月）
- [x] 実装言語 → Ruby（モロヘイヤとの知見共有）
- [x] VPS 構築 → flauros.b-shock.co.jp（Ubuntu 24.04 LTS）
- [x] リレーサーバーのドメイン名 → relay.capsicum.shrieker.net

## 未決事項

- [ ] v1.15 で発生した Swift ネイティブ層の起動不能問題の原因特定
- [x] 美食丼のプリセット扱い（#52 コメント参照）→ プリセットサーバーに追加済み
- [x] workmanager ポーリングの扱い → v1.19 (#348) で撤去。iOS BGTask 経路も含めて廃止済み
- [x] Web Push ペイロードの扱い → 暗号化のまま転送しクライアントで復号（#336、B 案採用）

## 関連 Issue・ドキュメント

- [#52](https://github.com/pooza/capsicum/issues/52) — プッシュ通知リレー（本体 Issue）
- [#293](https://github.com/pooza/capsicum/issues/293) — iOS 通知の観測性強化（観測結果: 発火 0回）
- [CLAUDE.md プッシュ通知セクション](CLAUDE.md#プッシュ通知)
- [release-pipeline.md](release-pipeline.md)
