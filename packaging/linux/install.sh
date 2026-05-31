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

REPO="pooza/capsicum"
LATEST_API="https://api.github.com/repos/$REPO/releases/latest"
# `curl … | bash` のワンライナー配信時、uninstall.sh は手元に無いので
# 同じ raw URL を案内する。capsicum-site (shrieker.net) で短縮配信する
# のはリリース後 (#640)。
RAW_BASE="https://raw.githubusercontent.com/$REPO/main/packaging/linux"

usage() {
  cat <<EOF
Usage: $0 [path-to-capsicum-*.AppImage]

With NO argument, downloads the latest capsicum AppImage from GitHub
Releases and installs it (designed for \`curl … | bash\` one-liner use).
With a path, installs that local AppImage instead.

Either way it places the AppImage into ~/Applications/, registers the
.desktop entry and hicolor icons under your user XDG directories, and
refreshes the desktop / icon caches.

A locally-passed AppImage is moved (not copied) — pass a copy if you
want to keep the original in place.
EOF
}

# HTTP 取得は curl 優先・wget フォールバック。`curl … | bash` で起動できて
# いる時点で curl は居るはずだが、wget だけの環境でも自己ダウンロードを通す。
fetch_stdout() {
  local url="$1"
  if command -v curl >/dev/null; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null; then
    wget -qO- "$url"
  else
    echo "error: neither curl nor wget is available" >&2
    return 1
  fi
}

download_to() {
  local url="$1" out="$2"
  if command -v curl >/dev/null; then
    curl -fSL --progress-bar "$url" -o "$out"
  elif command -v wget >/dev/null; then
    wget -q --show-progress -O "$out" "$url"
  else
    echo "error: neither curl nor wget is available" >&2
    return 1
  fi
}

# 一時ディレクトリは複数 (ダウンロード用 / 展開用) 作るのでまとめて掃除する。
CLEANUP_DIRS=()
cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [[ -n "$d" ]] && rm -rf "$d"
  done
  # 最後の [[ -n "$d" ]] が空配列で false (=1) になると、その戻り値が
  # `exit 0` 等の終了コードを上書きしてしまう (bash の EXIT トラップの
  # 仕様)。明示的に 0 を返して終了コードを保護する。
  return 0
}
trap cleanup EXIT

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  # ローカル指定モード: 既存の使い方 (引数で AppImage パスを渡す)。
  SRC="$1"
  if [[ ! -f "$SRC" ]]; then
    echo "error: $SRC is not a file" >&2
    exit 1
  fi
else
  # 自己ダウンロードモード: 最新 Release の x86_64 AppImage を取得する。
  ARCH=$(uname -m)
  if [[ "$ARCH" != "x86_64" ]]; then
    echo "error: only an x86_64 AppImage is provided (your arch: $ARCH)" >&2
    exit 1
  fi
  echo "==> Looking up the latest release"
  RELEASE_JSON=$(fetch_stdout "$LATEST_API")
  DOWNLOAD_URL=$(printf '%s\n' "$RELEASE_JSON" \
    | grep -m1 -oE 'https://[^"]+-x86_64\.AppImage' || true)
  if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "error: could not find an x86_64 AppImage asset in the latest release" >&2
    echo "       see $RAW_BASE/INSTALL.md for manual steps" >&2
    exit 1
  fi
  DL_DIR=$(mktemp -d -t capsicum-download-XXXXXX)
  CLEANUP_DIRS+=("$DL_DIR")
  SRC="$DL_DIR/$(basename "$DOWNLOAD_URL")"
  echo "==> Downloading $(basename "$DOWNLOAD_URL")"
  download_to "$DOWNLOAD_URL" "$SRC"
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
CLEANUP_DIRS+=("$EXTRACT_DIR")

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

To uninstall:
  curl -fsSL $RAW_BASE/uninstall.sh | bash
  (or run ./uninstall.sh if you downloaded it alongside this script)
EOF
