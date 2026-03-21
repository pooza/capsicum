# App Store Review Notes — Guideline 2.1 (Demo Account Login) 対応

## Resolution Center 返信文（英文）

```
Thank you for your review.

The demo account credentials are correct and have not changed. This same account was successfully used in previous reviews (including the Guideline 1.2 review where you tested reporting and blocking features).

Capsicum is a client for decentralized social networks (Mastodon / Misskey). Unlike typical social apps, login requires selecting a server first, then authenticating via a browser-based OAuth page.

We have simplified the Review Notes to contain only the login instructions, removing the previous supplementary notes to avoid confusion. Please refer to the updated Review Notes for the step-by-step guide.
```

## Review Notes 全文（既存の内容をすべて置き換える）

```
=== How to sign in ===

1. On the login screen, select "デルムリン丼" (mstdn.delmulin.com) from the preset server list.
2. Tap "ログイン" (Login).
3. Enter the demo account credentials (email and password) on the browser-based authorization page.
4. Tap "承認" (Authorize).

Note: Occasionally the screen may reload after tapping "承認" instead of returning to the app. The login has succeeded — simply close the browser view to continue.
```

## 提出手順

1. App Store Connect → Resolution Center → 返信文を貼り付け
2. App Store Connect → アプリ → v1.2.1 → App Review Information → Notes を上記 Review Notes 全文で**置き換え**（補足1・補足2は削除）
3. v1.2.1 を再提出
