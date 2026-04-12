# Google Play Review — アプリのアクセス権（ログイン手順）対応

## リジェクト内容

「提供されたユーザー名またはパスワードが機能しない」— 審査員が OAuth フローを理解できず、ログインに失敗。

## 「アプリのアクセス権」設定内容

### ユーザー名（メールアドレス）

審査用アカウントのメールアドレスを入力

### パスワード

審査用アカウントのパスワードを入力

### その他の手順

```
This app is a client for decentralized social networks (Mastodon / Misskey). Login requires selecting a server first, then authenticating via a browser-based OAuth page.

=== How to sign in ===

1. On the login screen, select "デルムリン丼" (mstdn.delmulin.com) from the preset server list.
2. Tap "ログイン" (Login).
3. A browser-based authorization page will open. Enter the demo account credentials (the email and password provided above).
4. Tap "承認" (Authorize) to grant access.
5. The app will return to the main screen automatically.

Note: The username and password fields above are NOT entered directly in the app. They are entered on the browser-based Mastodon authorization page that appears in step 3.
```

## 提出手順

1. Google Play Console → アプリのアクセス権 → 上記の手順説明を更新
2. 最新バージョンのビルドを製品版トラックにアップロード
3. 再提出
