# App Store Review Notes — Guideline 1.2 (UGC) 対応

## Review Notes（App Store Connect に貼り付ける英文）

```
Thank you for your feedback regarding Guideline 1.2 (User-Generated Content).

We have implemented the following features to comply with the guideline:

1. **EULA / Terms of Use Agreement**
   Users must agree to the Terms of Use on first launch before accessing any content. The agreement screen clearly states that the app has zero tolerance for inappropriate content and harassment, and that users can use the reporting and blocking features.

2. **Post Reporting**
   Users can report any post to the server administrator via the post action menu (long-press on a post → "通報" / Report). An optional reason can be provided. This works on both Mastodon and Misskey servers.

3. **User Blocking with Developer Notification**
   Users can block other users from the profile screen (⋮ menu → "ブロック" / Block). Blocking immediately removes the blocked user's content from the timeline. After blocking, a dialog asks whether the user wants to report the issue to the app developer. Choosing "報告する" (Report) opens the developer's contact form (https://contact.capsicum.shrieker.net) so the developer is notified of the inappropriate content.

4. **User Muting**
   Users can also mute other users with optional duration settings (30 minutes to 7 days).

Please see the attached screen recording demonstrating the full flow:
EULA agreement → post reporting → user blocking → developer notification prompt.
```

## 画面録画の撮影手順

1. アプリを新規インストール（または `SharedPreferences` をクリア）した状態で起動
2. EULA 同意画面が表示される → 「利用規約を読む」をタップ → 戻る → 「同意して続ける」をタップ
3. ログイン → タイムラインを表示
4. 任意の投稿を長押し → アクションメニュー → 「通報」をタップ → 理由を入力 → 「通報」ボタン
5. 任意のユーザーのプロフィールを開く → ⋮ メニュー → 「ブロック」→ 確認ダイアログで「ブロック」
6. 「開発者への報告」ダイアログが表示される → 「報告する」をタップ → お問い合わせフォームが開く
7. 録画を停止

## 提出先

- App Store Connect → アプリ → 該当バージョン → App Review Information → Notes
- 録画ファイルは Attachments に添付
