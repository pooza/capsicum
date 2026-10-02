#!/bin/sh
# deny-bare-cd-chain.sh の判定表。期待と実測が食い違ったら NG を出して exit 1。
H="$(dirname "$0")/deny-bare-cd-chain.sh"
fail=0

check() {
  want=$1
  desc=$2
  cmd=$3
  got=$(printf '%s' "$cmd" | jq -Rs '{tool_input: {command: .}}' | "$H" \
    | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  [ -z "$got" ] && got=allow
  if [ "$got" = "$want" ]; then
    printf 'ok    %-6s %s\n' "$got" "$desc"
  else
    printf 'NG    want=%s got=%s  %s\n' "$want" "$got" "$desc"
    fail=1
  fi
}

# 当てるべき形（#1198 の再発 5 件 + 2026-10-03 の 2 件が全部この形）
check deny  'cd + テスト（2026-10-03 に踏んだ形）' 'cd /repo/packages/capsicum && flutter test test/a_test.dart'
check deny  'cd + 別リポジトリの読み（2026-10-03 / #1198 の 2 番）' 'cd ~/repos/misskey && grep -rn foo src'
check deny  'cd + grep' 'cd /repo/packages/capsicum/lib && grep -rn Icons.search .'
check deny  'cd + ; 区切り' 'cd /repo; ls'
check deny  'cd + パイプ' 'cd /repo/packages/capsicum | tee /tmp/x'
check deny  '⚠ 単独の cd も拒否（2026-10-03 に強めた範囲）' 'cd /Volumes/extdata/repos/capsicum'
check deny  '⚠ cwd を戻す形も拒否（単独を許すとこれが要る）' 'cd /Volumes/extdata/repos/capsicum && pwd'
check deny  '継続行で && が次行へ渡る形' 'cd /repo &&
  flutter test'
check deny  '2 行目に cd が出る形' 'echo start
cd /repo && ls'
check deny  '先頭に空白がある形' '   cd /repo && ls'

# 当ててはいけない形
check allow '⚠⚠ サブシェルは通す（これが唯一の正しい書き方）' '(cd /repo/packages/capsicum && flutter test)'
check allow 'サブシェル 2 連' '(cd a && make) && (cd b && make)'
check allow 'サブシェルの継続行' '(cd /repo/packages/capsicum &&
  flutter test)'
check allow '引数に cd という語が出るだけ' 'grep -rn "cd" docs/dev-environment.md'
check allow 'コミット本文に cd の話が出る（heredoc は見ない）' 'git -C /repo commit -F - <<EOF
cd してから走らせる形をやめた
cd /repo && ls はもう書かない
EOF'
check allow 'git -C は通す' 'git -C /repo status --porcelain'
check allow 'melos 経由のテスト' 'dart run melos exec --scope=capsicum -- flutter test'
check allow 'cdr のような別コマンドを拾わない' 'cdr /repo'
check allow 'cd を含む語で始まる変数代入' 'cdpath=/repo && echo ok'

exit $fail
