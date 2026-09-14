# ログイントラブルシューティング

⚠⚠ **本文は Claude Code のスキルへ移した（#1114・2026-09-13）。このファイルはポインタで、切り分けの中身は持たない。**

- 正本: [.claude/skills/login-troubleshooting/SKILL.md](../.claude/skills/login-troubleshooting/SKILL.md)
- 呼び出し: **`/login-troubleshooting`**（「ログインできない」報告が来たとき）
- 扱う 2 系統: レートリミット（`POST /api/v1/apps`）/ ブラウザからアプリに戻れない（リダイレクト失敗。Mastodon と Misskey で手順が分かれる）

⚠ **頭から順に実行する手順ではない。**報告の文面から入口（どちらの症状か）を先に確定させる。
