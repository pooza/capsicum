#!/bin/bash
# Android の実機（adb）を操作して撮る（docs/screenshot-procedure.md）。
# 座標は画面の画素（スクショの座標）。
#
#   ANDROID_SERIAL=<serial> android.sh <コマンド> ...
#
#   demo on|off          ステータスバーをデモ表示（10:00・電池満タン・通知を隠す）
#   app                  capsicum（Play 版 net.shrieker.capsicum）を前面で起動する
#   tap <x> <y> / drag <x1> <y1> <x2> <y2> / hold <x> <y>
#   type <ASCII>         ⚠ adb の input text は ASCII だけ。空白は %s に置き換える
#   typesecret <VAR>     secrets.env の値を打つ（ASCII）
#   key <name>           BACK / HOME / ENTER / DEL / APP_SWITCH など
#   shot <name>          $SHOT_DIR/shots/<name>.png と縮小版 <name>_s.png
#
# ⚠ 普段遣いの Pixel 8 には使わない（書き換え禁止）。検証機の Pixel 6a で撮る。
set -u
source "$(dirname "$0")/lib.sh"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
APP="${ANDROID_APP:-net.shrieker.capsicum}"
[ -n "${ANDROID_SERIAL:-}" ] || { echo "ANDROID_SERIAL を指定する（adb devices）" >&2; exit 2; }
a() { "$ADB" -s "$ANDROID_SERIAL" "$@"; }
esc() { printf '%s' "$1" | sed -e 's/ /%s/g' -e "s/[&|<>;()\\\$\`'\"]/\\\\&/g"; }

case "${1:-}" in
  demo)
    if [ "$2" = on ]; then
      a shell settings put global sysui_demo_allowed 1
      for c in "clock -e hhmm 1000" "battery -e level 100 -e plugged false" \
        "network -e wifi show -e level 4 -e mobile hide -e airplane hide" "notifications -e visible false" "status -e volume hide -e bluetooth hide -e alarm hide"; do
        set -- $c
        a shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null
      done
      a shell am broadcast -a com.android.systemui.demo -e command enter >/dev/null
    else
      a shell am broadcast -a com.android.systemui.demo -e command exit >/dev/null
    fi ;;
  app) a shell monkey -p "$APP" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 ;;
  tap) a shell input tap "$2" "$3"; sleep 0.8 ;;
  drag) a shell input swipe "$2" "$3" "$4" "$5" 300; sleep 0.8 ;;
  hold) a shell input swipe "$2" "$3" "$2" "$3" 800; sleep 0.8 ;;
  type) a shell input text "$(esc "$2")"; sleep 0.3 ;;
  typesecret)
    source ~/.config/capsicum/secrets.env
    a shell input text "$(esc "${!2}")" >/dev/null; sleep 0.5 ;;
  key) a shell input keyevent "KEYCODE_$2"; sleep 0.5 ;;
  shot)
    a exec-out screencap -p > "$SHOT_DIR/shots/$2.png"
    sips -Z 900 "$SHOT_DIR/shots/$2.png" --out "$SHOT_DIR/shots/$2_s.png" >/dev/null
    echo "$SHOT_DIR/shots/$2_s.png" ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
