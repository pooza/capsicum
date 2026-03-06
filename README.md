# capsicum

Mastodon / Misskey 対応の Fediverse クライアント（Flutter）

## 機能

- Mastodon / Misskey 両対応（NodeInfo による自動検出）
- マルチアカウント
- タイムライン（ホーム / ローカル / ソーシャル / 連合）
- 投稿（公開範囲選択、CW、メディア添付）
- 通知
- 検索
- ブックマーク
- Misskey リアクション
- ストリーミング（WebSocket）
- カスタム絵文字
- ワードフィルタ
- モロヘイヤ連携

## 開発

```bash
# 依存関係の取得
melos bs

# コード生成
melos gen

# フォーマットチェック
dart format --set-exit-if-changed .

# 静的解析
dart analyze --fatal-infos
```

## ライセンス

[AGPL-3.0](LICENSE)
