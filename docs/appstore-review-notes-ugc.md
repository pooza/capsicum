# App Store Review Notes — Guideline 1.2 (UGC) 対応

## Resolution Center 返信文（英文）

```
Thank you for your feedback regarding Guideline 1.2 (User-Generated Content).

We have confirmed that all required precautions are already implemented. We have attached a new screen recording that clearly demonstrates each feature on a physical device.

The recording shows the following flow:

1. **Flagging objectionable content** (0:00–0:30)
   Long-press any post → action menu appears → tap "通報" (Report) → enter a reason → tap "通報" to submit the report to the server administrator.

2. **EULA / Terms of Use agreement** (0:30–0:50)
   On first launch, users must accept the Terms of Use before accessing any content. The agreement screen explicitly states zero tolerance for inappropriate content and the availability of reporting and blocking features.

3. **Blocking abusive users** (0:50–1:20)
   Open a user's profile → tap ⋮ menu → "ブロック" (Block) → confirm → the user's content is immediately removed from the timeline. A follow-up dialog asks whether to report the issue to the app developer.

Please see the attached recording for the complete demonstration.
```

## Review Notes（App Store Connect の Notes に貼り付ける英文）

```
=== How to sign in ===

1. On the login screen, select "デルムリン丼" (mstdn.delmulin.com) from the preset server list.
2. Tap "ログイン" (Login).
3. Enter the demo account credentials (email and password) on the browser-based authorization page.
4. Tap "承認" (Authorize).

Note: Occasionally the screen may reload after tapping "承認" instead of returning to the app. The login has succeeded — simply close the browser view to continue.

=== UGC Compliance (Guideline 1.2) ===

This app implements the following precautions for user-generated content:

1. **Flag objectionable content**: Long-press any post → "通報" (Report) in the action menu → enter optional reason → submit. The report is sent to the server administrator.

2. **EULA / Terms of Use**: Displayed on first launch. Users must accept before accessing any content. States zero tolerance for inappropriate content and availability of reporting/blocking.

3. **Block abusive users**: Open user profile → ⋮ menu → "ブロック" (Block). Content is immediately hidden. A follow-up dialog offers to report the issue to the app developer.

See attached screen recording for a demonstration of all three features.

=== Third-Party Client (Guideline 4.1(a)) ===

capsicum is an independent, third-party client for open-source decentralized social networking platforms. It is not affiliated with or endorsed by the Mastodon or Misskey projects. Both platforms are open-source software (AGPL-3.0):
- Mastodon: https://github.com/mastodon/mastodon
- Misskey: https://github.com/misskey-dev/misskey
```

## 画面録画の撮影手順

録画のポイント: **通報機能を最初にデモする**（今回の指摘の核心）。各セクションの時間配分を意識して、レビュアーが見落とさないようにする。

### 準備

- 実機（iPhone）で撮影すること（シミュレータ不可）
- アプリを新規インストール（または `SharedPreferences` をクリア）した状態にする

### 撮影手順

1. **通報機能のデモ**（最初に見せる — 最重要）
   - ログイン済みの状態でタイムラインを表示
   - 任意の投稿を長押し → アクションメニューが表示される
   - 「通報」をタップ → 理由入力ダイアログ → 理由を入力 → 「通報」ボタンをタップ
   - 通報完了のフィードバックを確認

2. **EULA 同意画面のデモ**
   - アプリをアンインストール → 再インストールして起動
   - EULA 同意画面が表示される
   - 「利用規約を読む」をタップ → 規約を表示 → 戻る
   - 「同意して続ける」をタップ

3. **ブロック機能のデモ**
   - ログイン後、任意のユーザーのプロフィールを開く
   - ⋮ メニュー → 「ブロック」→ 確認ダイアログで「ブロック」
   - 「開発者への報告」ダイアログが表示される → 「報告する」をタップ
   - お問い合わせフォームが開くことを確認

4. 録画を停止

### 注意事項

- 各操作の前に 1〜2 秒の間を置き、レビュアーが操作を追えるようにする
- 通報→EULA→ブロック の順序を厳守（指摘項目を最初に見せる）

## 提出手順

1. App Store Connect でメタデータ（サブタイトル・プロモーションテキスト・説明文）を更新
2. App Store Connect → アプリ → 最新バージョン → App Review Information → Notes を上記 Review Notes 全文で**置き換え**
3. 録画ファイルを Attachments に添付
4. Resolution Center に返信文（1.2 + 4.1(a)）を貼り付け
5. 再提出
