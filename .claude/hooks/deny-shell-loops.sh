#!/bin/sh
# PreToolUse(Bash) guard — シェルのループと関数定義を拒否する。
#
# なぜ機械で止めるのか:
#   ループや関数定義が入った Bash は allowlist に当たらず、中身が全部許可済みでも
#   必ず許可確認になる。docs/sync-procedure.md §0 に「使わない」と明記してあるが、
#   規約を書いた翌セッションに筆者自身が 3 回使った実績がある。読んで守る仕組みでは
#   止まらないと判断し、ハーネス側の拒否に移した（2026-08-25）。
#
# 代わりにやること: 1 対象 1 ツール呼び出しにして並列に投げる。並列のほうが速い。
#
# 対象外:
#   - コマンド置換 $(...) は塞がない。`git commit -m "$(cat <<'EOF' ...)"` が
#     標準のコミット手順なので、塞ぐとコミットが打てなくなる。
#   - heredoc の本文も見ない（下記）。
#
# ⚠ **このスクリプトに `set -o pipefail` を足さないこと (#1036)。**
#   下の判定は `printf ... | grep -q` の形をしている。`grep -q` はマッチした
#   時点で終了するので、pipefail を有効にすると「マッチしたときだけパイプライン
#   が失敗する」逆転が起き、**ループが検出できたときに限って素通りする**。
#   herestring (`<<<`) へ寄せる手もあるが、`#!/bin/sh` が dash の環境で動かなく
#   なるため採らない。pipefail を足さないことで担保する。

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

# heredoc の本文を落としてから検査する。
#
# ⚠ 落とさないと**コードファイルの書き出しが軒並み拒否される**。`cat > f <<'EOF'`
# で Dart / JS / Swift 等を流し込むと、`void dispose() {` のような無引数メソッドが
# 下の「関数定義」パターンに一致する。2026-08-25 に #1032 の実装で実際に踏んだ。
# 見たいのは「シェルとして実行される部分」だけなので、区切り語までの中身は捨てる。
#
# awk 内の \047 はシングルクォート。sh の '...' に素で書けないための逃げ。
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
    # <<< は herestring であって heredoc ではない。区切り語と誤読しないよう潰す。
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

# 改行を空白へ潰す。`for x in a<改行>do` の形も 1 行として検査するため
# (grep は行単位なので、潰さないと複数行のループ header を取り逃がす)。
flat=$(printf '%s' "$scrubbed" | tr '\n\t' '  ')

# for / while / until ... ; do ... done
# ⚠ header の形 (`; do` または空白区切りの `do`) と `done` の両方が揃ったときだけ拒否する。
# `for` と `done` の有無だけで見ると、それらを含む散文 (コミットメッセージ等) を誤爆する。
if printf '%s\n' "$flat" | grep -qE '(^|[;&|(]|[[:space:]])(for|while|until)[[:space:]][^;&|]*[;[:space:]][[:space:]]*do([[:space:]]|$)' &&
  printf '%s\n' "$flat" | grep -qE '(^|[;&|]|[[:space:]])done([[:space:]]|[;&|)]|$)'; then
  deny 'シェルのループは許可確認になるため拒否した (docs/sync-procedure.md §0)。1 対象 1 ツール呼び出しに展開し、同一メッセージ内で並列に投げ直すこと。'
fi

# name() { ... }  /  function name { ... }
if printf '%s\n' "$scrubbed" | grep -qE '(^|[;&|]|[[:space:]])[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' ||
  printf '%s\n' "$scrubbed" | grep -qE '(^|[;&|]|[[:space:]])function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*'; then
  deny 'シェルの関数定義は許可確認になるため拒否した (docs/sync-procedure.md §0)。定義せずに済む形へ展開すること。なお、コードファイルの作成・編集は Bash ではなく Write / Edit ツールで行うこと。'
fi

exit 0
