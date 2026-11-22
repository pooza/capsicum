#!/bin/sh
# PreToolUse(Bash) guard — セッションのキーリング（gnome-keyring / Secret Service）を変える操作を拒否する（#1414）。
#
# なぜ機械で止めるのか:
#   2026-11-22 の #1403 の検証（inori）で、キーリングのロック中の表示を見るために
#   **セッションのキーリングを直接いじった**（テスト用キーリングの作成・項目の移動・
#   ロック）。途中で ChangeWithPrompt を外から呼んで gnome-keyring-daemon を落とし、
#   「ログイン」キーリングがロックされた。gh のトークンもキーリングにあるので、
#   pooza が push のためにキーリングのパスワードを打ち、gh にログインし直すことに
#   なった。#1386 でも同じ形（テスト用キーリングを既定にしたまま残した）。
#   pooza:「検証のための不便を、この先負い続けるのは嫌」。メモリに書いただけでは
#   また踏むので、機械で止める。
#
# 止める形（セッションのバスに向いているもの）:
#   - busctl / gdbus / dbus-send で org.freedesktop.secrets の Lock / Unlock /
#     CreateCollection / ChangeWith* / Delete / SetAlias / CreateItem / SetSecret を呼ぶ
#   - secret-tool の store / clear / lock / unlock
#   - gnome-keyring-daemon を kill / pkill / killall する、systemctl で
#     stop / restart / kill / reload / mask / disable する
#   - ~/.local/share/keyrings を rm / mv / cp / tee / truncate / shred / ln する
#   - libsecret / Secret Service を書き換える Python スクリプト（ファイルの中身を見る）を実行する
# 通す形:
#   - `tool/linux/keyring-sandbox.sh` を通す / `dbus-run-session` の中で動かす /
#     `DBUS_SESSION_BUS_ADDRESS=` で別のバスを指す（隔離したキーリングでの検証。これが正しいやり方）
#   - 読むだけの操作（SearchItems・get-property・ReadAlias・secret-tool lookup / search）
#
# ⚠ このスクリプトに `set -o pipefail` を足さないこと（deny-shell-loops.sh と同じ理由・
#   #1036。`grep -q` がマッチ時点で抜けると、検出できたときに限って素通りする）。

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

# heredoc の本文は見ない（コミットや Issue の本文でこの話を書いて誤爆しないため・
# deny-cd-then-git.sh と同じ処理）。awk 内の \047 はシングルクォート。
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

# 隔離したバスで動かしているなら、セッションのキーリングには届かない。
# tool/linux/keyring-sandbox.sh は私設のバスを立て、その中で動かす道具（#1414）。
if printf '%s\n' "$scrubbed" | grep -Eq 'dbus-run-session|DBUS_SESSION_BUS_ADDRESS=|keyring-sandbox\.sh'; then
  exit 0
fi

reason='セッションのキーリング（gnome-keyring / Secret Service）を変える操作は拒否した（#1414）。2026-11-22 に検証でセッションのキーリングを触り、daemon を落として「ログイン」キーリングをロックさせ、pooza に push のためのパスワード入力と gh のログインし直しをさせた。キーリングの検証は `tool/linux/keyring-sandbox.sh`（隔離したバスと専用の gnome-keyring を立て、その中で動かす・使い方はスクリプトの冒頭）で行うこと。セッションのキーリングの修理がどうしても要るなら、自分では行わず、理由を添えて pooza に頼むこと。⚠ この話を*文章として*書いていて落ちた場合は、本文を heredoc か `--body-file` / `-F` へ移すこと（本文は検査していない）。'

# ⚠ ここから下の grep の正規表現では、awk の `\t` / `\047` は使えない（grep では
#   タブ・引用符にならず、`\` と文字そのものになる）。空白は [[:space:]]、引用符は $q。
q="'"
methods="[[:space:].](Lock|LockService|Unlock|CreateCollection|ChangeWithPrompt|ChangeWithMasterPassword|Delete|SetAlias|CreateItem|SetSecret)([[:space:]\"$q]|\$)"
if printf '%s\n' "$scrubbed" | grep -E 'busctl|gdbus|dbus-send' \
  | grep 'org\.freedesktop\.secrets' | grep -Eq "$methods"; then
  deny "$reason"
fi

if printf '%s\n' "$scrubbed" | grep -Eq 'secret-tool[[:space:]]+(store|clear|lock|unlock)([[:space:]]|$)'; then
  deny "$reason"
fi

if printf '%s\n' "$scrubbed" | grep -E '(^|[[:space:];&|(])(kill|pkill|killall)[[:space:]]' | grep -q 'gnome-keyring'; then
  deny "$reason"
fi
if printf '%s\n' "$scrubbed" | grep -E 'systemctl[[:space:]].*(stop|restart|kill|reload|mask|disable)[[:space:]]' \
  | grep -q 'gnome-keyring'; then
  deny "$reason"
fi

if printf '%s\n' "$scrubbed" | grep -E '(^|[[:space:];&|(])(rm|mv|cp|tee|truncate|shred|ln)[[:space:]]' \
  | grep -q '\.local/share/keyrings'; then
  deny "$reason"
fi

# Python のスクリプトは中身を見る。libsecret / Secret Service を使い、かつ書き換える
# 呼び出しを含むものを実行する形を止める。
for py in $(printf '%s\n' "$scrubbed" | grep -E '(^|[[:space:];&|(])python3?[[:space:]]' \
  | grep -oE "[^[:space:];&|()\"$q]+\\.py"); do
  case "$py" in
    \~/*) py="$HOME/${py#\~/}" ;;
  esac
  [ -f "$py" ] || continue
  if grep -Eq 'org\.freedesktop\.secrets|require_version\("Secret"|Secret\.Service' "$py" \
    && grep -Eq 'create_sync|lock_sync|unlock_sync|set_alias|ChangeWith|delete_sync|CreateCollection|CreateItem|SetAlias|"Lock"|"Unlock"|"Delete"' "$py"; then
    deny "$reason"
  fi
done

exit 0
