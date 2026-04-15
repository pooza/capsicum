# App Store Review Notes — Guideline 1.2 (UGC) 対応

## Resolution Center 返信文（英文）

```
Thank you for your review. All three required precautions — flagging content, EULA, and blocking users — are already fully implemented. Please see the attached screen recording and the detailed walkthrough below.

IMPORTANT: The report/flag feature is accessed by LONG-PRESSING (tap and hold) on any post. This opens an action menu that includes a "通報" (Report) button. This is a deliberate design choice to prevent accidental taps — the same interaction pattern used by Apple's own Messages app for message reactions.

Here is what the recording demonstrates (in order):

1. EULA / TERMS OF USE
   - On first launch, a Terms of Use screen is displayed
   - Users must accept before accessing any content
   - The agreement explicitly states zero tolerance for inappropriate content and the availability of reporting and blocking features

2. FLAG OBJECTIONABLE CONTENT
   - Long-press (tap and hold) any post in the timeline
   - An action menu slides up from the bottom
   - Tap "通報" (Report) — the flag icon
   - A dialog appears asking for an optional reason
   - Tap "通報" (Report) to submit
   - The report is sent directly to the server administrator

3. BLOCK ABUSIVE USERS
   - Open the reported user's profile
   - Tap the ⋮ menu in the top-right corner
   - Tap "ブロック" (Block) and confirm
   - The user's content is immediately removed from all timelines
   - A follow-up dialog offers to report the issue to the app developer

All three features are fully functional and demonstrated in the attached recording.
```

## Review Notes（App Store Connect の Notes に貼り付ける英文）

```text
=== UGC Compliance (Guideline 1.2) — PLEASE READ BEFORE TESTING ===

All three required precautions are implemented. A screen recording demonstrating each feature is attached.

*** HOW TO FLAG OBJECTIONABLE CONTENT ***

The report feature is accessed via LONG-PRESS (tap and hold) on any post:

1. Long-press (tap and hold) any post in the timeline
2. An action menu slides up from the bottom of the screen
3. Tap the flag icon labeled "通報" (Report)
4. Enter an optional reason in the dialog
5. Tap "通報" (Report) to submit the report to the server administrator

Note: The long-press interaction is intentional to prevent accidental reports — the same pattern used by Apple Messages for reactions.

*** EULA / TERMS OF USE ***

On first launch, users must accept the Terms of Use before accessing any content. The agreement states zero tolerance for inappropriate content and the availability of reporting and blocking features.

*** BLOCKING ABUSIVE USERS ***

1. Open any user's profile
2. Tap the ⋮ menu (top-right)
3. Tap "ブロック" (Block) and confirm
4. The user's content is immediately hidden from all timelines
5. A follow-up dialog offers to report the issue to the app developer

=== How to sign in ===

1. On the login screen, select "デルムリン丼" (mstdn.delmulin.com) from the preset server list.
2. Tap "ログイン" (Login).
3. Enter the demo account credentials (email and password) on the browser-based authorization page.
4. Tap "承認" (Authorize).

Note: Occasionally the screen may reload after tapping "承認" instead of returning to the app. The login has succeeded — simply close the browser view to continue.

=== Third-Party Client (Guideline 4.1(a)) ===

capsicum is an independent, third-party client for open-source decentralized social networking platforms. It is not affiliated with or endorsed by the Mastodon or Misskey projects. Both platforms are open-source software (AGPL-3.0):
- Mastodon: https://github.com/mastodon/mastodon
- Misskey: https://github.com/misskey-dev/misskey
```

## 画面録画の撮影手順

### 準備

- 実機（iPhone）で撮影すること（シミュレータ不可）
- アプリを新規インストール（または `SharedPreferences` をクリア）した状態にする

### 撮影手順

1. **ログイン**
   - アプリを起動 → EULA 画面はスキップせずそのまま進む（手順 2 で見せる）
   - デルムリン丼を選択してログイン

2. **EULA 同意画面のデモ**
   - 初回起動時の EULA 同意画面が表示される
   - 「利用規約を読む」をタップ → 規約を表示 → 戻る
   - 「同意して続ける」をタップ

3. **ブロック機能のデモ**
   - タイムラインから任意のユーザーのプロフィールを開く
   - ⋮ メニュー → 「ブロック」→ 確認ダイアログで「ブロック」

4. **通報機能のデモ**
   - タイムラインで任意の投稿を長押し → アクションメニューが表示される
   - 「通報」をタップ → 理由入力ダイアログ → 理由を入力 → 「通報」ボタンをタップ
   - 通報完了のフィードバックを確認

5. **開発者への問い合わせフォーム**
   - 「開発者への報告」ダイアログが表示される → 「報告する」をタップ
   - お問い合わせフォームが開くことを確認

6. 録画を停止

### 注意事項

- 各操作の前に 1〜2 秒の間を置き、レビュアーが操作を追えるようにする

## 提出手順

1. App Store Connect でメタデータ（サブタイトル・プロモーションテキスト・説明文）を更新
2. App Store Connect → アプリ → 最新バージョン → App Review Information → Notes を上記 Review Notes 全文で**置き換え**
3. 録画ファイルを Attachments に添付
4. Resolution Center に返信文（1.2 + 4.1(a)）を貼り付け
5. 再提出
