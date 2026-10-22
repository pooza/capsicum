#!/bin/bash
# tool/screenshot の共通部分。各スクリプトが source する。
#
# 作業用の置き場（トークン・撮影ログ・撮った画像）は $SHOT_DIR。
# 既定は ~/.cache/capsicum-screenshot。トークンを置くので 700 にする。

SHOT_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOT_DIR="${SHOT_DIR:-$HOME/.cache/capsicum-screenshot}"
mkdir -p "$SHOT_DIR/tokens" "$SHOT_DIR/shots" "$SHOT_DIR/bin"
chmod 700 "$SHOT_DIR" "$SHOT_DIR/tokens"

# Swift の小道具は初回に bin/ へビルドする（ソースが新しければ作り直す）。
shot_bin() {
  local name="$1"
  local src="$SHOT_TOOL_DIR/$name.swift"
  local bin="$SHOT_DIR/bin/$name"
  if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
    swiftc -O -o "$bin" "$src" >&2 || return 1
  fi
  echo "$bin"
}

# プリセットの 4 台。キーは secrets.env の TEST_<KEY>_EMAIL / _PASSWORD と揃える。
shot_host() {
  case "$1" in
    BSHOCKDON) echo mstdn.b-shock.org ;;
    DELMULINDON) echo mstdn.delmulin.com ;;
    CURESTA) echo precure.ml ;;
    DAISSKEY) echo misskey.delmulin.com ;;
    *) echo "unknown server key: $1 (BSHOCKDON / DELMULINDON / CURESTA / DAISSKEY)" >&2; return 1 ;;
  esac
}

shot_is_misskey() { [ "$1" = DAISSKEY ]; }

shot_token() {
  local f="$SHOT_DIR/tokens/$1"
  [ -s "$f" ] || { echo "token がない: ${f}（fedi.sh token ${1}）" >&2; return 1; }
  cat "$f"
}
