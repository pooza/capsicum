#!/bin/sh
# PreToolUse(Bash) guard — サブシェルで囲まない `cd` の複合コマンドを拒否する。
#
# なぜ機械で止めるのか:
#   `cd` は**次のツール呼び出しにも残る**。docs/dev-environment.md「コマンドの
#   書き方」はそのため `cd` しない規約を置いているが、⚠⚠ **2026-10-01 の 1
#   セッションで 5 回、2026-10-03 にも 2 回破った**（#1198）。読んで守る仕組みの
#   限界なので、インタプリタのインライン実行・`cd` してから `git` と同じ答えを
#   採る（MEMORY「守れない規約はフック化」）。
#
#   ⚠ 事故の本体（別リポジトリを掴んだ `gh` の誤爆・2026-09-04）は #1189 の
#   deny-cd-then-git.sh と `gh --repo` / `git -C` の固定で既に塞がっている。
#   ここで止めるのは**その手前** —— cwd が動いたまま後続が走る形そのもの。
#
# ⚠⚠ **サブシェルの外の `cd` は、単独でも拒否する**（2026-10-03 pooza 判断で
#   当初案より強めた）。⚠ **「単独の `cd X` なら意図が明確だから通す」という線は
#   採らない** —— 単独でも cwd は残るので、**残った cwd を戻すためにまた `cd` を
#   打つ**という形になり、規約の目的（cwd を動かさない）を満たさない。ルールが
#   「サブシェルの外に `cd` を書かない」の 1 行で済むほうが守りやすい。
#   ⚠ このフックは Claude の Bash 呼び出しにしか掛からないので、pooza 自身の
#   ターミナル操作は縛らない。
#
# ⚠ **サブシェルは通す。**`(cd X && cmd)` は cwd を残さない（#1198 で実測・CI の
#   analyze.yml も既にこの形）。⚠⚠ **`flutter test` / `dart test` / `pod install`
#   には `git -C` に相当するオプションが無い**ので、この抜け道を閉じると正しい
#   書き方が無くなる。**ここだけが例外。**
#
# 代わりにやること:
#   - サブシェルで囲む → `(cd X && cmd)`
#   - リポジトリを指定できるものは指定する → `git -C <path>` / `gh --repo`
#   - 上流のソースを読む → 絶対パスで `sed` / `grep`
#   - パッケージのテスト → `dart run melos exec --scope=capsicum -- flutter test`
#
# ⚠ **既知の穴: `cd` が行頭に無い形は見ていない**（`export FOO=1 && cd X && cmd`）。
#   #1198 で決めた範囲が「`cd` で始まる複合コマンド」なので、広げるなら別途判断する。
#   実績のある形は全部行頭なので、まずここだけ塞ぐ。
#
# ⚠ **このスクリプトに `set -o pipefail` を足さないこと。**判定は
#   `printf ... | awk` の形で、pipefail を有効にすると**検出できたときに限って
#   素通りする**逆転が起きうる（deny-shell-loops.sh / deny-cd-then-git.sh の
#   同じ注意書きと同一の理由・#1036）。

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
# ⚠ 落とさないと**コミットや Issue の本文が誤爆する**。この規約の話を文章として
# 書くと、それ自身が拒否される（このフックを入れるコミットがまさにその形）。
# ⚠ heredoc の *開始行* は残す（そこにコマンドが出る）。
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

# 行ごとに「先頭が `cd` か」だけを見る。
#
# ⚠ **先頭で見ないと誤爆する。**`grep cd file` や `--message "cd"` のように
# 引数として現れる語を拾ってしまう。
# ⚠ **`(` で始まる行は通す**（サブシェル）。閉じ括弧の対応までは見ない —— 見ても
# 得が無く、`(cd X && a) && (cd Y && b)` のような形で誤爆する側に倒れる。
hit=$(printf '%s\n' "$scrubbed" | awk '
  BEGIN { hit = 0 }
  {
    s = $0
    sub(/^[ \t]+/, "", s)
    if (s ~ /^\(/) next
    if (s ~ /^cd([ \t]|$)/) hit = 1
  }
  END { print hit }
')

if [ "$hit" = "1" ]; then
  deny 'サブシェルの外の `cd` は拒否した (docs/dev-environment.md「コマンドの書き方」/ #1198)。⚠ `cd` は次のツール呼び出しにも残るので、数手あとのコマンドが別のディレクトリ・別のリポジトリで走る（2026-09-04 に上流 mastodon/mastodon へのコメント誤爆を実際に起こしている）。書き直し方: (1) サブシェルで囲む `(cd X && cmd)` —— `flutter test` / `dart test` / `pod install` はこの形（CI も同じ）。(2) リポジトリを指定できるものは指定する `git -C <path>` / `gh --repo`。(3) 上流のソースを読むなら絶対パスで `sed` / `grep`。(4) パッケージのテストは `dart run melos exec --scope=capsicum -- flutter test`。⚠⚠ **単独の `cd X` も拒否する** —— 単独でも cwd は残り、戻すためにまた `cd` を打つことになるため。⚠ この規約の話を*文章として*書いていて落ちた場合は、本文を heredoc か `--body-file` / `-F` へ移すこと（本文は検査していない）。'
fi

exit 0
