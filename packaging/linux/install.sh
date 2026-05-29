#!/usr/bin/env bash
# capsicum AppImage デスクトップ統合インストール (#640)
#
# 配布対象は AppImage 単独 (Flathub 断念 #604) のため、放置するとアプリ
# メニューに登録されず GUI ランチャーから起動できない。AppImageLauncher を
# 入れていない環境向けに、最低限のメニュー / アイコン登録を一発で行う。
#
# 使い方:
#   ./install.sh /path/to/capsicum-x.y.z-x86_64.AppImage
#
# 配置先 (すべてユーザー領域):
#   $HOME/Applications/capsicum-x.y.z-x86_64.AppImage
#   $HOME/.local/share/applications/net.shrieker.capsicum.desktop
#   $HOME/.local/share/icons/hicolor/<size>/apps/net.shrieker.capsicum.png
#
# システム領域には書き込まない (sudo 不要)。
# アンインストールは同梱の uninstall.sh を使う。

set -euo pipefail

APP_ID="net.shrieker.capsicum"
APP_NAME="capsicum"
APPLICATIONS_DIR="$HOME/Applications"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_BASE="$HOME/.local/share/icons/hicolor"

usage() {
  cat <<EOF
Usage: $0 <path-to-capsicum-*.AppImage>

Installs the AppImage into ~/Applications/, registers the .desktop entry
and hicolor icons under your user XDG directories, and refreshes the
desktop / icon caches.

The AppImage file itself is moved (not copied) — pass a copy if you want
to keep the original in place.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

SRC="$1"
if [[ ! -f "$SRC" ]]; then
  echo "error: $SRC is not a file" >&2
  exit 1
fi

# AppImage に展開コマンド (`--appimage-extract`) を渡せるよう、まず実行
# 権限を付与しておく (chmod 済みでも no-op)。
chmod +x "$SRC"

FILENAME=$(basename "$SRC")
case "$FILENAME" in
  capsicum-*.AppImage) ;;
  *)
    echo "warn: file name '$FILENAME' does not look like a capsicum AppImage" >&2
    ;;
esac

mkdir -p "$APPLICATIONS_DIR"
DEST="$APPLICATIONS_DIR/$FILENAME"
if [[ "$SRC" != "$DEST" ]]; then
  echo "==> Installing AppImage to $DEST"
  mv -f "$SRC" "$DEST"
fi
chmod +x "$DEST"

# AppImage の中身 (.desktop / hicolor アイコン) を一時ディレクトリに展開
# して再利用する。リポジトリのファイル構成を仮定しないので、AppImage 単独
# + install.sh だけで動く。
EXTRACT_DIR=$(mktemp -d -t capsicum-install-XXXXXX)
trap 'rm -rf "$EXTRACT_DIR"' EXIT

echo "==> Extracting AppImage payload to $EXTRACT_DIR"
pushd "$EXTRACT_DIR" >/dev/null
"$DEST" --appimage-extract >/dev/null
popd >/dev/null

SQUASH="$EXTRACT_DIR/squashfs-root"
SRC_DESKTOP="$SQUASH/usr/share/applications/$APP_ID.desktop"
SRC_ICON_BASE="$SQUASH/usr/share/icons/hicolor"

if [[ ! -f "$SRC_DESKTOP" ]]; then
  echo "error: .desktop entry not found in AppImage at $SRC_DESKTOP" >&2
  exit 1
fi

mkdir -p "$DESKTOP_DIR"
DEST_DESKTOP="$DESKTOP_DIR/$APP_ID.desktop"
# Exec は元の `capsicum %U` (= $PATH 解決前提) のままだとランチャーから
# 起動できないので、実体の AppImage を絶対パスで指す。AppImage 内に
# StartupWMClass / Icon は既に書かれているのでそれ以外はそのまま流す。
echo "==> Writing $DEST_DESKTOP"
sed -E "s|^Exec=.*|Exec=$DEST %U|" "$SRC_DESKTOP" > "$DEST_DESKTOP"

if [[ ! -d "$SRC_ICON_BASE" ]]; then
  echo "warn: hicolor icons not found at $SRC_ICON_BASE — skipping icons" >&2
else
  echo "==> Installing hicolor icons under $ICON_BASE"
  while IFS= read -r -d '' icon; do
    rel="${icon#"$SRC_ICON_BASE/"}"
    dst="$ICON_BASE/$rel"
    mkdir -p "$(dirname "$dst")"
    cp -f "$icon" "$dst"
  done < <(find "$SRC_ICON_BASE" -type f -name "$APP_ID.png" -print0)
fi

# キャッシュ更新は best-effort。コマンド不在のディストロでも進行する。
if command -v update-desktop-database >/dev/null; then
  echo "==> Refreshing desktop database"
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null; then
  echo "==> Refreshing icon cache"
  # -t: 古いキャッシュでもエラーにしない、-q: silent
  gtk-update-icon-cache -t -q "$ICON_BASE" >/dev/null 2>&1 || true
fi

cat <<EOF

Installed $APP_NAME to $DEST
Desktop entry: $DEST_DESKTOP
Icons: $ICON_BASE/*/apps/$APP_ID.png

You should now see $APP_NAME in your application menu.
If not, log out and log back in to refresh the launcher.

To uninstall, run:
  ./uninstall.sh
EOF
