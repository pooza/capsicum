# docs/archive

現役運用では参照しない過去の記録を置くディレクトリ。削除するには惜しいが、日常的に参照するものではない資料をまとめる。

## 方針

- ここに入っているファイルは **歴史的な記録** として扱う。通常の開発作業では参照しない
- 将来、類似の状況（審査リジェクト等）が再発した場合の参考資料としての価値がある
- 現行運用に関わるドキュメントを誤ってここに入れないこと

## 収録ファイル

### ストア審査対応の記録

v1.0 前後の初回審査時に遭遇したリジェクトへの対応記録。v1.14.0 時点で両ストア（App Store / Google Play）公開済みであり、これらの対応は完了している。

- [appstore-review-notes-copycats.md](appstore-review-notes-copycats.md) — App Store Guideline 4.1(a)（Copycats）リジェクトへの返信文と対応
- [appstore-review-notes-login.md](appstore-review-notes-login.md) — App Store Guideline 2.1（デモアカウントログイン）リジェクトへの返信文
- [appstore-review-notes-ugc.md](appstore-review-notes-ugc.md) — App Store Guideline 1.2（UGC）リジェクトへの返信文と操作説明
- [googleplay-review-notes-login.md](googleplay-review-notes-login.md) — Google Play 審査員の OAuth ログイン失敗への対応記録

### 設計判断の経緯記録

実装が完了し正本が別の場所に移ったため、設計判断の経緯のみが歴史的価値として残るドキュメント。

- [push-relay-plan.md](push-relay-plan.md) — プッシュ通知リレー (capsicum-relay) の初期計画書。Ruby / Linode / Linode Nanode / flauros.b-shock.co.jp 等の選定根拠を含む。v1.18 で実装済、本番は [pooza/capsicum-relay](https://github.com/pooza/capsicum-relay) リポジトリが正本。Stage 3 (外部ユーザー向け有償提供) は [#597](https://github.com/pooza/capsicum/issues/597) で継続
- [privacy-policy.md](privacy-policy.md) — capsicum 初期 (v1.0) のプライバシーポリシー草稿。現行は [capsicum.shrieker.net/privacy-policy](https://capsicum.shrieker.net/privacy-policy) ([capsicum-site](https://github.com/pooza/capsicum-site) の `privacy-policy/index.md`) が正本
- [release-pipeline.md](release-pipeline.md) — リリースパイプライン構想（fastlane + GitHub Actions）。Phase 1〜4（iOS/Android 自動化 → macOS → Linux → Windows）が v1.32 までに全て実現済みで、構想としての役目を終えた。日々の運用手順は [store-release-guide.md](../store-release-guide.md) が正本。タグ命名規則・責務分担・macOS の Mac App Store 一本化方針などの設計経緯の記録として保持
