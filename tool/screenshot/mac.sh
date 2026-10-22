#!/bin/bash
# macOS の capsicum（debug）を操作して撮る（docs/screenshot-procedure.md）。
# 座標は窓の左上からの相対（ポイント）。窓は 1440x900（Mac App Store の 16:10）。
#
#   mac.sh fit                窓を (240,60) に 1440x900 で置く
#   mac.sh tap <x> <y>
#   mac.sh drag <x1> <y1> <x2> <y2>
#   mac.sh paste <文字列>     クリップボード経由で貼る（日本語はこちら）
#   mac.sh key <code>         36=Return 51=Delete 53=Esc
#   mac.sh shot <name>        窓の範囲を撮る → $SHOT_DIR/shots/<name>.png と _s
#   mac.sh blur <in> <out> <x> <y> <w> <h> [半径]   矩形をぼかす（動画・ジャケット）
#
# ⚠ paste は pooza のクリップボードを上書きする。
# ⚠ MAC_WX / MAC_W を変えると、動画の横の狭い窓（例: MAC_WX=1040 MAC_W=640）を操作できる。
set -u
source "$(dirname "$0")/lib.sh"
WX=${MAC_WX:-240}; WY=${MAC_WY:-60}; W=${MAC_W:-1440}; H=${MAC_H:-900}
TAP="$(shot_bin simtap)" || exit 1
front() { osascript -e 'tell application "System Events" to tell process "capsicum" to set frontmost to true' -e 'delay 0.3'; }

case "${1:-}" in
  fit)
    osascript -e 'tell application "System Events" to tell process "capsicum"' \
      -e "set position of window 1 to {$WX, $WY}" -e "set size of window 1 to {$W, $H}" -e 'end tell' ;;
  tap) front; "$TAP" tap $((WX + $2)) $((WY + $3)); sleep 0.8 ;;
  drag) front; "$TAP" drag $((WX + $2)) $((WY + $3)) $((WX + $4)) $((WY + $5)) 30; sleep 0.8 ;;
  paste) printf '%s' "$2" | pbcopy; front; osascript -e 'tell application "System Events" to keystroke "v" using command down'; sleep 0.5 ;;
  key) front; osascript -e "tell application \"System Events\" to key code $2"; sleep 0.3 ;;
  shot)
    screencapture -x -o -R "$WX,$WY,$W,$H" "$SHOT_DIR/shots/$2.png"
    sips -Z 900 "$SHOT_DIR/shots/$2.png" --out "$SHOT_DIR/shots/$2_s.png" >/dev/null
    echo "$SHOT_DIR/shots/$2_s.png" ;;
  blur) shift; "$(shot_bin blur)" "$@" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
