#!/bin/sh
# deny-session-keyring-changes.sh の判定表。期待と実測が食い違ったら NG を出して exit 1。
H="$(dirname "$0")/deny-session-keyring-changes.sh"
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

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

# 書き換える Python（2026-11-22 の kr_all.py の形）と、読むだけの Python
cat > "$T/mutate.py" <<'EOF'
import gi
gi.require_version("Secret", "1")
from gi.repository import Secret
svc = Secret.Service.get_sync(Secret.ServiceFlags.OPEN_SESSION, None)
svc.lock_sync([], None)
EOF
cat > "$T/readonly.py" <<'EOF'
from gi.repository import Gio
BUS.call_sync("org.freedesktop.secrets", "/org/freedesktop/secrets",
    "org.freedesktop.Secret.Service", "SearchItems", None, None, 0, 5000, None)
EOF
cat > "$T/other.py" <<'EOF'
print("lock_sync is just a word here")
EOF

# 当てるべき形（2026-11-22 に踏んだ形を含む）
check deny  '⚠ 踏んだ形: busctl で Lock' 'busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service Lock ao 1 /org/freedesktop/secrets/collection/login'
check deny  '⚠ 踏んだ形: ChangeWithPrompt' 'busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface ChangeWithPrompt o /org/freedesktop/secrets/collection/login'
check deny  '⚠ 踏んだ形: コレクションの Delete' 'busctl --user call org.freedesktop.secrets /org/freedesktop/secrets/collection/x org.freedesktop.Secret.Collection Delete'
check deny  '⚠ 踏んだ形: SetAlias' 'busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service SetAlias so default /org/freedesktop/secrets/collection/login'
check deny  'Unlock（解除の画面を出しうる）' 'busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service Unlock ao 1 /x'
check deny  'gdbus の形' 'gdbus call --session --dest org.freedesktop.secrets --object-path /org/freedesktop/secrets --method org.freedesktop.Secret.Service.Lock "[]"'
check deny  'secret-tool store' 'secret-tool store --label=x account y'
check deny  'secret-tool clear' 'secret-tool clear account net.shrieker.capsicum.secureStorage'
check deny  'daemon を kill' 'pkill -STOP gnome-keyring-daemon'
check deny  '⚠ 踏んだ形: systemctl で restart' 'systemctl --user restart gnome-keyring-daemon.service && sleep 2'
check deny  'キーリングのファイルを消す' 'rm -f ~/.local/share/keyrings/login.keyring'
check deny  'キーリングのファイルを写す' 'cp -p ~/.local/share/keyrings/* /tmp/b/'
check deny  '⚠ 踏んだ形: 書き換える Python を実行' "python3 -I $T/mutate.py move /a /b"
check deny  '環境変数を前置きした Python' "KR_OLD=x python3 -I $T/mutate.py KR_OLD"

# 当ててはいけない形
check allow '⚠⚠ dbus-run-session の中（隔離したキーリング）' "dbus-run-session -- sh -c 'gnome-keyring-daemon --unlock --components=secrets; busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service Lock ao 0'"
check allow '⚠⚠ keyring-sandbox.sh を通す（隔離したキーリング）' 'tool/linux/keyring-sandbox.sh run /tmp/s/kr secret-tool store --label=x account y'
check allow 'keyring-sandbox.sh で lock' 'tool/linux/keyring-sandbox.sh lock /tmp/s/kr'
check allow '別のバスを指す' 'DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/s/bus busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service Lock ao 0'
check allow '読むだけ: SearchItems' "busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service SearchItems 'a{ss}' 1 application chrome"
check allow '読むだけ: Locked の get-property' 'busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked'
check allow '読むだけ: ReadAlias' 'busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service ReadAlias s default'
check allow '読むだけ: secret-tool lookup' 'secret-tool lookup account net.shrieker.capsicum.secureStorage | jq keys'
check allow 'daemon の状態を見る' 'systemctl --user status gnome-keyring-daemon.service'
check allow 'キーリングの一覧を見る' 'ls -la ~/.local/share/keyrings/'
check allow '読むだけの Python' "python3 -I $T/readonly.py"
check allow 'Secret Service と無関係の Python' "python3 -I $T/other.py"
check allow '別の D-Bus の呼び出し' 'busctl --user call net.shrieker.capsicum /net/shrieker/capsicum org.freedesktop.Application ActivateAction sava{sv} quit 0 0'
check allow 'heredoc の本文は見ない' 'gh issue comment 1 --body-file - <<EOF
busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service Lock ao 1 /x
systemctl --user restart gnome-keyring-daemon.service
EOF'

exit $fail
