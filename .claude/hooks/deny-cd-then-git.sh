#!/bin/sh
# PreToolUse(Bash) guard — 同じコマンドの中で `cd` してから `git` を叩く形を拒否する。
#
# なぜ機械で止めるのか:
#   docs/dev-environment.md「コマンドの書き方」の「他リポジトリへ `cd` してから
#   `git`」をやらない（`git -C <path>` を使う）という規約を、⚠⚠ **2026-09-29 の
#   1 セッション中に 3 回破った**（#1189）。インタプリタのインライン実行
#   (2026-08-23 / 08-25 / 09-28) と同じ経過なので、同じ答え —— 読んで守る仕組み
#   から外す。
#
#   ⚠ 減らしたいのは許可確認だけではない。**`cd` は次のツール呼び出しにも残る**
#   ので、数手あとの `gh` が別リポジトリを掴む。2026-09-04 に上流の
#   `mastodon/mastodon` へコメントを投稿する誤爆を実際に起こしている
#   （docs/dev-environment.md「`cd` は次のツール呼び出しにも残る」）。
#
# ⚠ **`cd` そのものは塞がない（#1189 の案 1）。**`flutter` / `pod install` など
#   ディレクトリに依存するツールがあり、pooza 自身の手作業も壊せない。
#   **塞ぐのは事故の本体である「`cd` のあとの `git`」だけ**。
#
# 代わりにやること:
#   - 他リポジトリの git を読む → `git -C <path> <sub>`
#   - パッケージ配下でテストを回す → `dart run melos exec --scope=capsicum -- flutter test`
#   - 上流のソースを読む → 絶対パスで `sed` / `grep`
#
# ⚠ **このスクリプトに `set -o pipefail` を足さないこと。**判定は
#   `printf ... | grep -q` / `awk` の形で、`grep -q` はマッチ時点で終了するため、
#   pipefail を有効にすると**検出できたときに限って素通りする**逆転が起きる
#   （deny-shell-loops.sh の同じ注意書きと同一の理由・#1036）。

cmd=$(jq -r '.tool_input.command // ""')

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# heredoc の本文は見ない。
#
# ⚠ 落とさないと**コミットや Issue の本文が誤爆する**。`git commit -F - <<'EOF'`
# の本文で「`cd` してから `git`」の話を書くと、それ自身が拒否される（この
# フックを入れるコミットがまさにその形）。見たいのは「シェルとして実行される
# 部分」だけ。⚠ heredoc の *開始行* は残す（そこにコマンドが出る）。
#
# awk 内の \047 はシングルクォート（sh の '...' に素で書けないための逃げ）。
scrubbed=$(printf '%s\n' "$cmd" | awk '
  BEGIN { delim = "" }
  delim != "" {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line == delim) delim = ""
    next
  }
  {
    s = $0
    gsub(/<<</, "  ", s)
    if (match(s, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
      d = substr(s, RSTART, RLENGTH)
      sub(/^<<-?[ \t]*/, "", d)
      gsub(/[\047"]/, "", d)
      delim = d
    }
    print
  }
')

# 区切り（`;` / `&&` / `||` / `|` / 括弧 / 改行）で区切った各断片の**先頭**だけを見る。
#
# ⚠ **先頭で見ないと誤爆する。**`grep cd file` や `--message "cd"` のように
# 引数として現れる語を拾ってしまう。
# ⚠ **順序を見る。**`git -C x status && cd packages/capsicum` は規約違反ではない
# （`cd` のあとに `git` が来たときだけ落とす）。
# ⚠⚠ **`git -C` は通す。**それが規約の求める形そのもの。`cd` が別のツール
# （`dart` / `flutter`）のために置かれていて、git は `-C` で書いてある形まで
# 落とすと、正しい書き方が使えなくなる（このフックを入れた直後に踏んだ）。
# ⚠ 改行も区切りなので、`cd x` と `git status` が別の行にあっても当たる。
hit=$(printf '%s\n' "$scrubbed" | awk '
  BEGIN { cd_seen = 0; hit = 0 }
  {
    n = split($0, seg, /(&&|\|\||[;&|()])/)
    for (i = 1; i <= n; i++) {
      s = seg[i]
      sub(/^[ \t]+/, "", s)
      if (s ~ /^cd([ \t]|$)/) cd_seen = 1
      else if (cd_seen == 1 && s ~ /^git([ \t]|$)/ && s !~ /[ \t]-C/) hit = 1
    }
  }
  END { print hit }
')

if [ "$hit" = "1" ]; then
  deny '`cd` してから `git` を叩く形は拒否した (docs/dev-environment.md「コマンドの書き方」/ #1189)。`git -C <path> <sub>` で書き直すこと（`-C` 付きは通る）。⚠ cd は次のツール呼び出しにも残るので、数手あとの `gh` が別リポジトリを掴む（2026-09-04 に上流へのコメント誤爆を起こしている）。パッケージ配下でテストを回すなら `dart run melos exec --scope=capsicum -- flutter test`、上流のソースを読むなら絶対パスで `sed` / `grep`。⚠ この規約の話を*文章として*書いていて落ちた場合は、本文を heredoc か `--body-file` / `-F` へ移すこと（本文は検査していない）。'
fi

exit 0
