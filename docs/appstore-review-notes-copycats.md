# App Store Review Notes — Guideline 4.1(a) (Copycats) 対応

## Resolution Center 返信文（英文）

```
Thank you for your feedback regarding Guideline 4.1(a).

Mastodon and Misskey are open-source, decentralized social networking platforms — not proprietary products or services owned by a single company.

- Mastodon is released under the GNU Affero General Public License (AGPL-3.0): https://github.com/mastodon/mastodon
- Misskey is released under the GNU Affero General Public License (AGPL-3.0): https://github.com/misskey-dev/misskey

capsicum is an independent, third-party client that connects to these open platforms. It is not affiliated with, endorsed by, or impersonating the official Mastodon or Misskey projects. This is analogous to how third-party email clients connect to email servers, or how third-party web browsers render web content.

We have revised the App Store metadata (subtitle, promotional text, and description) to make the third-party nature of the app clearer and to reduce any appearance of affiliation with these projects.
```

## 対応内容

### メタデータの修正

| 項目 | 変更前 | 変更後 |
|------|--------|--------|
| サブタイトル | Mastodon / Misskey クライアント | Fediverse クライアント |
| 短い説明文 | Mastodon / Misskey 対応の Fediverse クライアント。複数アカウントに対応。 | Fediverse クライアント。複数サーバー・アカウントに対応。 |
| プロモーションテキスト | Mastodon も Misskey も、ひとつのアプリで。 | 分散型SNSを、ひとつのアプリで。 |
| 説明文冒頭 | capsicum は、Mastodon と Misskey に対応した Fediverse クライアントアプリです。 | capsicum は、分散型SNS（Fediverse）に対応したサードパーティクライアントアプリです。Mastodon・Misskey などのオープンソース SNS プラットフォームに接続できます。 |

### 変更しない項目

- **Keywords**: 検索用であり、ユーザーが実際に検索する語句（Mastodon, Misskey 等）は維持
- **説明文の機能一覧**: 「Misskey リアクション」等の機能名は事実の記述であり、impersonation にあたらない

## 提出手順

1. App Store Connect でメタデータ（サブタイトル・プロモーションテキスト・説明文）を更新
2. Resolution Center に返信文を貼り付け
3. Guideline 1.2 の対応と合わせて再提出
