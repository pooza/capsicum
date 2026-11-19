#!/bin/sh
# deny-appimage-without-launcher-disable.sh の判定表。期待と実測が食い違ったら NG を出して exit 1。
H="$(dirname "$0")/deny-appimage-without-launcher-disable.sh"
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

# 当てるべき形（2026-11-18 に踏んだ形を含む）
check deny  '⚠ 踏んだ形: 変数に入れて nohup で起動' 'A=/repo/build/linux/dist/capsicum-2.13.0-x86_64.AppImage; XDG_DATA_HOME=/tmp/d nohup $A > /tmp/l 2>&1 & echo started'
check deny  '⚠ 踏んだ形: 変数を引用符つきで起動' 'A=/x/c.AppImage; XDG_DATA_HOME=/tmp/d "$A" >| /tmp/l 2>&1'
check deny  '直接起動' '/home/pooza/Applications/capsicum-2.13.0-x86_64.AppImage'
check deny  '相対パス' './capsicum-2.13.0-x86_64.AppImage --some-flag'
check deny  'env で包む' 'env FOO=1 /x/c.AppImage'
check deny  'timeout で包む' 'timeout 30 /x/c.AppImage'
check deny  '&& のあと' 'ls /x && /x/c.AppImage'
check deny  'サブシェルの中' '(/x/c.AppImage)'
check deny  '⚠ 0 は無効扱い' 'APPIMAGELAUNCHER_DISABLE=0 /x/c.AppImage'
check deny  '⚠ 起動の後ろで付けても効かない' '/x/c.AppImage; export APPIMAGELAUNCHER_DISABLE=1'

# 当ててはいけない形
check allow '⚠⚠ 前置きで付ける（正しい形）' 'APPIMAGELAUNCHER_DISABLE=1 /x/c.AppImage'
check allow '前置き + nohup + 背後' 'APPIMAGELAUNCHER_DISABLE=1 XDG_DATA_HOME=/tmp/d nohup /x/c.AppImage > /tmp/l 2>&1 &'
check allow '変数経由 + 前置き' 'A=/x/c.AppImage; APPIMAGELAUNCHER_DISABLE=1 nohup "$A" &'
check allow 'export を先に' 'export APPIMAGELAUNCHER_DISABLE=1; /x/c.AppImage'
check allow '単独の代入を先に' 'APPIMAGELAUNCHER_DISABLE=1; export APPIMAGELAUNCHER_DISABLE; /x/c.AppImage'
check allow 'ランタイムの展開（アプリは起動しない）' "(cd /tmp/s && /x/c.AppImage --appimage-extract 'usr/lib/lib*')"
check allow '引数に出るだけ（ls）' 'ls -la /x/c.AppImage'
check allow '引数に出るだけ（cp）' 'cp /x/c.AppImage /tmp/s/test.AppImage'
check allow 'appimagetool の出力' 'ARCH=x86_64 appimagetool /x/AppDir /x/c.AppImage'
check allow '統合済みの symlink（拡張子なし）' '~/Applications/capsicum'
check allow 'grep で語が出るだけ' 'grep -n "AppImage" docs/a.md'
check allow 'heredoc の本文は見ない' 'gh issue comment 1 --body-file - <<EOF
/x/c.AppImage を起動した
EOF'

exit $fail
