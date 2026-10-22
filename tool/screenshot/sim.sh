#!/bin/bash
# iOS シミュレータ（Xcode 27 の DeviceHub）を操作して撮る（docs/screenshot-procedure.md）。
#
#   SIM=iphone|ipad sim.sh <コマンド> ...
#
#   boot                 起動し、ステータスバーを 9:41・電池満タンにする
#   fit                  DeviceHub の窓を決まった位置・大きさに置く（座標の前提）
#   lang <en|ja>         iOS の言語を切り替えて再起動する（英字の入力は en で）
#   app                  capsicum（debug）を前面で起動する
#   tap <px> <py>        シミュレータの画素座標をタップ
#   drag <x1> <y1> <x2> <y2>
#   hold <px> <py>       長押し
#   type <英数字>        キー入力（⚠ ja では ローマ字→かな になる）
#   typesecret <VAR>     secrets.env の値をキー入力（画面にもログにも出さない）
#   key <code>           36=Return 49=Space 51=Delete 53=Esc
#   shot <name>          $SHOT_DIR/shots/<name>.png と縮小版 <name>_s.png
#
# ⚠⚠ Mac の画面がロック中だと何も届かない（ioreg -n Root -d1 | grep IOConsoleLocked）。
set -u
source "$(dirname "$0")/lib.sh"

# DeviceHub の窓（fit で置く）と、その中のシミュレータの表示位置・倍率。
# ⚠ 「ウィンドウに合わせる」で拡大した状態を前提に、2026-10-21 に実測した値。
#   機種を変えたら calibrate の手順（docs）で測り直す。
WX=820; WY=30; WW=1100; WH=985
case "${SIM:-iphone}" in
  iphone) UDID="${SIM_UDID:-340CABC5-5AFD-4746-AC48-F2C132E191D5}"; LEFT=487; TOP=90; SCALE=3.548; ORIENT="" ;;  # iPhone 18 Pro Max
  ipad) UDID="${SIM_UDID:-494BB3A7-4CEE-4224-AE71-23EE144CAA32}"; LEFT=300; TOP=216; SCALE=3.674; ORIENT="Landscape Left" ;;  # iPad Pro 13-inch (M5)
  *) echo "SIM は iphone か ipad" >&2; exit 2 ;;
esac
APP=jp.co.b-shock.capsicum.debug

to_screen() { awk -v px="$1" -v py="$2" -v wx=$WX -v wy=$WY -v l=$LEFT -v t=$TOP -v s=$SCALE \
  'BEGIN { printf "%d %d", wx + l + px / s, wy + t + py / s }'; }
front() { osascript -e 'tell application "DeviceHub" to activate' -e 'delay 0.3'; }
statusbar() { xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3; }
orient() {
  [ -n "$ORIENT" ] || return 0
  front; osascript -e "tell application \"System Events\" to tell process \"DeviceHub\" to click menu item \"$ORIENT\" of menu 1 of menu item \"Orientation\" of menu 1 of menu bar item \"Device\" of menu bar 1" >/dev/null
  sleep 2
}
reboot() {
  xcrun simctl shutdown "$UDID" 2>/dev/null
  xcrun simctl boot "$UDID" && xcrun simctl bootstatus "$UDID" -b >/dev/null
  statusbar; orient
}

TAP="$(shot_bin simtap)" || exit 1
case "${1:-}" in
  boot)
    xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b >/dev/null
    open /Applications/Xcode.app/Contents/Applications/DeviceHub.app; sleep 2; statusbar; orient ;;
  fit)
    osascript -e 'tell application "DeviceHub" to activate' \
      -e "tell application \"System Events\" to tell process \"DeviceHub\" to set position of window 1 to {$WX, $WY}" \
      -e "tell application \"System Events\" to tell process \"DeviceHub\" to set size of window 1 to {$WW, $WH}" ;;
  lang)
    if [ "$2" = en ]; then L='en-US ja-JP'; else L='ja-JP'; fi
    xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleLanguages -array $L
    reboot; xcrun simctl launch "$UDID" "$APP" >/dev/null ;;
  app)
    # ⚠ Safari などから戻るとステータスバーに「◀ Safari」が残る。終了して開き直すと消える。
    xcrun simctl terminate "$UDID" "$APP" 2>/dev/null; xcrun simctl launch "$UDID" "$APP" >/dev/null ;;
  tap) read -r X Y <<< "$(to_screen "$2" "$3")"; front; "$TAP" tap "$X" "$Y"; sleep 1 ;;
  drag)
    read -r X1 Y1 <<< "$(to_screen "$2" "$3")"; read -r X2 Y2 <<< "$(to_screen "$4" "$5")"
    front; "$TAP" drag "$X1" "$Y1" "$X2" "$Y2" 30; sleep 1 ;;
  hold) read -r X Y <<< "$(to_screen "$2" "$3")"; front; "$TAP" drag "$X" "$Y" "$X" "$Y" 60; sleep 1 ;;
  type) front; osascript -e 'on run argv' -e 'tell application "System Events" to keystroke (item 1 of argv)' -e 'end run' "$2" >/dev/null; sleep 0.3 ;;
  typesecret)
    source ~/.config/capsicum/secrets.env
    front; osascript -e 'on run argv' -e 'tell application "System Events" to keystroke (item 1 of argv)' -e 'end run' "${!2}" >/dev/null; sleep 0.5 ;;
  key) front; osascript -e "tell application \"System Events\" to key code $2"; sleep 0.3 ;;
  shot)
    xcrun simctl io "$UDID" screenshot "$SHOT_DIR/shots/$2.png" >/dev/null 2>&1
    sips -Z 900 "$SHOT_DIR/shots/$2.png" --out "$SHOT_DIR/shots/$2_s.png" >/dev/null
    echo "$SHOT_DIR/shots/$2_s.png" ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
