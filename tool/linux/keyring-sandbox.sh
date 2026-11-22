#!/bin/sh
# 隔離したキーリング（gnome-keyring / Secret Service）の中で capsicum を動かす（#1414）。
#
# ⚠⚠ キーリングの検証は、必ずこの中で行う。セッションのキーリング（本物）を触ると、
#   pooza が解除のパスワードを打ったり gh にログインし直したりすることになる
#   （2026-11-22 に実際に起こした）。本物を変える操作は .claude/hooks/
#   deny-session-keyring-changes.sh が止める。
#
# 仕組み（docs/tech-notes.md「隔離して実機検証する型」）:
#   - dbus-run-session で私設のセッションバスを作り、その上に専用の
#     gnome-keyring-daemon を立てる（org.freedesktop.secrets の接続先が本物と別になる）
#   - キーリングの実体（$XDG_DATA_HOME/keyrings）とアプリのデータを DIR の下へ分ける
#   - daemon には XDG_RUNTIME_DIR も DIR の下を渡す。⚠ 渡さないと
#     /run/user/<uid>/keyring の本物を見つけて起動を譲る
#   - 先に --unlock でキーリングを作っておく。⚠ 無いと解除の画面を待って固まる
#   - freeze / thaw（SIGSTOP / SIGCONT）は、PID がこの DIR の daemon だと確かめてから送る
#
# 使い方:
#   tool/linux/keyring-sandbox.sh start DIR [PREFS_JSON]
#       DIR に隔離した環境を作って立てる（背後に残る）。PREFS_JSON を渡すと、
#       capsicum の shared_preferences.json として置く（アカウントの一覧だけを持ち込む）
#   tool/linux/keyring-sandbox.sh run DIR CMD [ARGS...]
#       その中で CMD を動かす。APPIMAGELAUNCHER_DISABLE=1 は付けてある
#       （例: run DIR nohup build/linux/dist/capsicum-X-x86_64.AppImage）
#   tool/linux/keyring-sandbox.sh lock DIR      キーリングをロックする
#   tool/linux/keyring-sandbox.sh freeze DIR    daemon を止める（応答しない・#1085 の型）
#   tool/linux/keyring-sandbox.sh thaw DIR      止めた daemon を戻す
#   tool/linux/keyring-sandbox.sh status DIR    ロックの有無と daemon の状態
#   tool/linux/keyring-sandbox.sh stop DIR      片付ける（DIR は残す）
#
# 解除の画面が出たときのパスワードは `sandbox`（KEYRING_SANDBOX_PASSWORD で変えられる）。
# 入力は tool/linux/remote_input.py の `type sandbox` で打てる。
#
# ⚠ アプリは私設のバスを見るので、本物の capsicum が動いていても別の窓として起動する
#   （単一起動の判定もそのバスで行われる）。

set -eu

PASSWORD=${KEYRING_SANDBOX_PASSWORD:-sandbox}
COLL=/org/freedesktop/secrets/collection/login

die() { echo "keyring-sandbox: $*" >&2; exit 1; }

usage() { sed -n '/^# 使い方:/,/^# ⚠ アプリは/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ $# -ge 2 ] || usage
op=$1
dir=$2
shift 2

load_env() {
  [ -f "$dir/env" ] || die "$dir は立っていない（start を先に）"
  # shellcheck disable=SC1091
  . "$dir/env"
}

# この DIR の daemon であることを確かめる（本物や別のプロセスへ signal を送らない）。
check_pid() {
  [ -n "${KEYRING_PID:-}" ] && [ "$KEYRING_PID" -gt 1 ] 2>/dev/null || die "PID が不正: ${KEYRING_PID:-}"
  [ -r "/proc/$KEYRING_PID/environ" ] || die "PID $KEYRING_PID は動いていない"
  case $(cat "/proc/$KEYRING_PID/comm") in
    gnome-keyring-d*) ;;
    *) die "PID $KEYRING_PID は gnome-keyring-daemon ではない" ;;
  esac
  tr '\0' '\n' < "/proc/$KEYRING_PID/environ" | grep -qx "XDG_RUNTIME_DIR=$dir/runtime" \
    || die "PID $KEYRING_PID はこの DIR の daemon ではない（本物の可能性）"
}

bus() { busctl --address="$BUS" "$@"; }

case $op in
  start)
    [ ! -e "$dir/env" ] || die "$dir はもう立っている（stop してから）"
    mkdir -p "$dir/data/keyrings" "$dir/config" "$dir/runtime"
    chmod 700 "$dir" "$dir/runtime" "$dir/data/keyrings"
    dir=$(cd "$dir" && pwd)
    rm -f "$dir/stop"
    if [ $# -ge 1 ]; then
      mkdir -p "$dir/data/capsicum"
      cp "$1" "$dir/data/capsicum/shared_preferences.json"
    fi
    XDG_DATA_HOME="$dir/data" XDG_CONFIG_HOME="$dir/config" XDG_RUNTIME_DIR="$dir/runtime" \
      KEYRING_SANDBOX_PASSWORD="$PASSWORD" \
      nohup dbus-run-session -- sh "$0" _inner "$dir" > "$dir/sandbox.log" 2>&1 &
    i=0
    while [ ! -f "$dir/env" ]; do
      i=$((i + 1))
      [ $i -le 100 ] || die "立ち上がらなかった（$dir/sandbox.log を見る）"
      sleep 0.1
    done
    load_env
    echo "started: $dir（bus $BUS・keyring PID $KEYRING_PID）"
    ;;

  _inner)
    # dbus-run-session の中。DBUS_SESSION_BUS_ADDRESS は私設のバスを指している。
    printf '%s' "$PASSWORD" | gnome-keyring-daemon --unlock --components=secrets > "$dir/daemon.env"
    i=0
    pid=
    while [ -z "$pid" ]; do
      i=$((i + 1))
      [ $i -le 100 ] || { echo "daemon が見つからない" >&2; exit 1; }
      pid=$(busctl --address="$DBUS_SESSION_BUS_ADDRESS" status org.freedesktop.secrets 2>/dev/null \
        | sed -n 's/^PID=//p')
      [ -n "$pid" ] || sleep 0.1
    done
    busctl --address="$DBUS_SESSION_BUS_ADDRESS" call org.freedesktop.secrets /org/freedesktop/secrets \
      org.freedesktop.Secret.Service SetAlias so default "$COLL" > /dev/null
    # capsicum の項目（中身は空の JSON）を置いておく。⚠ 置かないと、ロック中かの判定
    # （SecretServiceProbe.isLocked・capsicum の項目で見る）が「ロックされていない」を
    # 返し、自動の再試行が読みに行って解除の画面を出す。利用者のキーリングには必ず
    # この項目があるので、置いておくほうが実態に近い（2026-11-22 に踏んだ）。
    printf '{}' | secret-tool store --label='net.shrieker.capsicum/FlutterSecureStorage' \
      account net.shrieker.capsicum.secureStorage \
      xdg:schema net.shrieker.capsicum/FlutterSecureStorage
    {
      echo "BUS='$DBUS_SESSION_BUS_ADDRESS'"
      echo "KEYRING_PID=$pid"
    } > "$dir/env.tmp"
    mv "$dir/env.tmp" "$dir/env"
    while [ ! -e "$dir/stop" ]; do sleep 1; done
    kill -CONT "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    ;;

  run)
    load_env
    [ $# -ge 1 ] || usage
    exec env DBUS_SESSION_BUS_ADDRESS="$BUS" XDG_DATA_HOME="$dir/data" XDG_CONFIG_HOME="$dir/config" \
      APPIMAGELAUNCHER_DISABLE=1 "$@"
    ;;

  lock)
    load_env
    bus call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service \
      Lock ao 1 "$COLL" > /dev/null
    echo "locked"
    ;;

  freeze)
    load_env
    check_pid
    kill -STOP "$KEYRING_PID"
    echo "frozen: PID $KEYRING_PID"
    ;;

  thaw)
    load_env
    check_pid
    kill -CONT "$KEYRING_PID"
    echo "thawed: PID $KEYRING_PID"
    ;;

  status)
    load_env
    check_pid
    state=$(sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$KEYRING_PID/status")
    echo "daemon: PID $KEYRING_PID（state $state・T なら freeze 中）"
    if [ "$state" = T ]; then
      echo "locked: 分からない（freeze 中は答えない）"
    else
      echo "locked: $(bus get-property org.freedesktop.secrets "$COLL" org.freedesktop.Secret.Collection Locked)"
    fi
    ;;

  stop)
    load_env
    touch "$dir/stop"
    i=0
    while kill -0 "$KEYRING_PID" 2>/dev/null; do
      i=$((i + 1))
      [ $i -le 50 ] || die "daemon が止まらない（PID $KEYRING_PID）"
      sleep 0.1
    done
    rm -f "$dir/env" "$dir/stop"
    echo "stopped: $dir"
    ;;

  *) usage ;;
esac
