#!/bin/sh
# PreToolUse(Bash) guard — インタプリタのインライン実行を拒否する。
#
# 拒否するのは **コードをコマンドラインに直書きする形**だけ:
#   python3 -c '...'  /  python3 - <<PY  /  perl -e  /  perl -pi -e  /  ruby -e  /  node -e
#
# ⚠ **スクリプトファイルの実行は通す**（`python3 tool/foo.py` 等）。禁じたいのは
#   「インタプリタに逃げること」であって「その言語を使うこと」ではない。
#
# なぜ機械で止めるのか:
#   2026-08-22 の実測で、直近 50 セッションの python3 596 回 / perl 106 回が
#   **許可確認の最大の発生源**だった。インタプリタ＝任意コード実行なので
#   allowlist に載せられず（載せても auto モードの分類器が無視しうる）、
#   書き方を変えるしかない。docs/dev-environment.md「コマンドの書き方」に
#   明記してあるが、⚠⚠ **2026-08-23 / 08-25 / 09-28 と繰り返し破られている**
#   （09-28 は 1 セッションで 3 回）。読んで守る仕組みでは止まらないと判断した。
#
# 代わりにやること:
#   - JSON の整形・抽出 → jq（`gh --jq` / `curl | jq`）
#   - ファイルの書き換え → Edit / Write ツール。⚠ **複数行の置換こそ Edit の出番**
#   - どうしても要る集計・横断解析 → **スクラッチパッドにスクリプトを書いて実行**
#     （Write で書けば差分が会話に残り、確認が「レビューできる 1 本」に対して出る）
#
# ⚠ **このスクリプトに `set -o pipefail` を足さないこと。**判定は
#   `printf ... | grep -q` の形で、`grep -q` はマッチ時点で終了するため、
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
# ⚠ 落とさないと**コードファイルの書き出しが誤爆する**。`cat > f <<'EOF'` で
# Python や JS を流し込むと、本文中の `perl -e` の話（ドキュメント等）まで拾う。
# 見たいのは「シェルとして実行される部分」だけ。
#
# ⚠⚠ **ただし heredoc の *開始行* は残す。**`python3 - <<'PY'` は開始行に
# インタプリタが現れるので、そこで捕まえられる（本文は捨ててよい）。
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

flat=$(printf '%s' "$scrubbed" | tr '\n\t' '  ')

interp='(python3?|perl|ruby|node)'

# 1) `-c` / `-e` でコードを直書きする形。
#
# ⚠ `-e` は perl / ruby / node の「式を実行」。**python の -e は無い**が、
# まとめて見ても誤爆しない（python -e は元々エラー）。
# ⚠ `ruby -Ilib -Itest foo_test.rb` のような **`-e` を含まないオプション列は通す。**
if printf '%s\n' "$flat" |
  grep -qE "(^|[;&|(]|[[:space:]])$interp([[:space:]]+-[A-Za-z0-9]+)*[[:space:]]+-(c|e)([[:space:]]|$)"; then
  deny 'インタプリタへコードを直書きする形 (python3 -c / perl -e 等) は許可確認の最大の発生源なので拒否した (docs/dev-environment.md「コマンドの書き方」)。JSON は jq、ファイルの書き換えは Edit / Write ツール。⚠ 複数行の置換こそ Edit の出番であって、インタプリタに逃げる理由にはならない。どうしても要る集計・横断解析は、スクラッチパッドにスクリプトを書いてから実行すること（その形なら通る）。'
fi

# 2) 標準入力からコードを流し込む形（`python3 - <<PY` / `python3 <<PY` / `... | python3`）。
#
# ⚠ `-` が引数のとき、および heredoc / パイプでインタプリタに入力を渡すとき。
# ⚠ **ファイル名を渡す形は当たらない**（`python3 foo.py` は通る）。
if printf '%s\n' "$flat" |
  grep -qE "(^|[;&|(]|[[:space:]])$interp([[:space:]]+-[A-Za-z0-9]+)*[[:space:]]+-([[:space:]]|$)"; then
  deny 'インタプリタへ標準入力でコードを流し込む形 (python3 - <<PY 等) は拒否した (docs/dev-environment.md「コマンドの書き方」)。⚠ スクラッチパッドにスクリプトを書いて `python3 <ファイル>` で実行すれば通る（コードが差分として会話に残り、確認も 1 回で済む）。'
fi

if printf '%s\n' "$flat" |
  grep -qE "(^|[;&|(]|[[:space:]])$interp([[:space:]]+-[A-Za-z0-9]+)*[[:space:]]*<<"; then
  deny 'インタプリタへ heredoc でコードを流し込む形は拒否した (docs/dev-environment.md「コマンドの書き方」)。⚠ スクラッチパッドにスクリプトを書いて `python3 <ファイル>` で実行すれば通る。'
fi

if printf '%s\n' "$flat" | grep -qE "\|[[:space:]]*$interp([[:space:]]+-[A-Za-z0-9]+)*([[:space:]]|$)"; then
  deny 'パイプでインタプリタへ流し込む形は拒否した (docs/dev-environment.md「コマンドの書き方」)。JSON の整形・抽出は jq で書くこと（`curl ... | jq -r` / `gh api ... --jq`）。'
fi

exit 0
