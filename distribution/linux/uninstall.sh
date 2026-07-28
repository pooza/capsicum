#!/usr/bin/env bash
# capsicum AppImage デスクトップ統合のアンインストール (#640)
#
# install.sh が配置した「メニュー登録 + アイコン + ~/Applications 配下の
# AppImage」を削除する。アカウント情報 (libsecret 由来) と app 設定 / ログ
# は触らない (それらの削除手順は INSTALL.md を参照)。
#
# 使い方:
#   ./uninstall.sh

set -euo pipefail

APP_ID="net.shrieker.capsicum"
APPLICATIONS_DIR="$HOME/Applications"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_BASE="$HOME/.local/share/icons/hicolor"

DESKTOP_ENTRY="$DESKTOP_DIR/$APP_ID.desktop"

# Exec= 行から実体の AppImage パスを抜き出して同時に消す。install.sh が
# 上書きで書いた前提なので、ユーザーが手動編集していなければ参照は壊れて
# いない。#707 以降は Exec が安定 symlink (~/Applications/capsicum) を指す
# ため、symlink ならリンク先の実体 AppImage も併せて消す。旧来 (#707 以前)
# は Exec がバージョン付き AppImage を直接指している。
if [[ -f "$DESKTOP_ENTRY" ]]; then
  EXEC_LINE=$(grep -E "^Exec=" "$DESKTOP_ENTRY" | head -1 | sed -E "s|^Exec=||" || true)
  EXEC_PATH="${EXEC_LINE% %U}"
  if [[ -L "$EXEC_PATH" ]]; then
    TARGET=$(readlink -f "$EXEC_PATH" || true)
    if [[ -n "$TARGET" && -f "$TARGET" && "$TARGET" == "$APPLICATIONS_DIR/"* ]]; then
      echo "==> Removing AppImage $TARGET"
      rm -f "$TARGET"
    fi
    echo "==> Removing symlink $EXEC_PATH"
    rm -f "$EXEC_PATH"
  elif [[ -f "$EXEC_PATH" && "$EXEC_PATH" == "$APPLICATIONS_DIR/"* ]]; then
    echo "==> Removing AppImage $EXEC_PATH"
    rm -f "$EXEC_PATH"
  fi
  echo "==> Removing desktop entry $DESKTOP_ENTRY"
  rm -f "$DESKTOP_ENTRY"
else
  echo "warn: desktop entry not found at $DESKTOP_ENTRY (already uninstalled?)" >&2
fi

# 上の Exec= 追跡は最新 (symlink 先) しか消さない。install.sh は最新 + 直前
# 1 世代を残すため、残った旧 AppImage が孤児になる。アンインストールでは
# 自前の命名 (capsicum-*-x86_64.AppImage) に一致する実ファイルを一掃する。
# 他アプリの AppImage や手製 symlink には触れない。
if [[ -d "$APPLICATIONS_DIR" ]]; then
  while IFS= read -r -d '' appimage; do
    echo "==> Removing AppImage $appimage"
    rm -f "$appimage"
  done < <(
    find "$APPLICATIONS_DIR" -maxdepth 1 -type f \
      -name 'capsicum-*-x86_64.AppImage' -print0
  )
fi

if [[ -d "$ICON_BASE" ]]; then
  while IFS= read -r -d '' icon; do
    echo "==> Removing icon $icon"
    rm -f "$icon"
  done < <(find "$ICON_BASE" -type f -name "$APP_ID.png" -print0)
fi

if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null; then
  gtk-update-icon-cache -t -q "$ICON_BASE" >/dev/null 2>&1 || true
fi

cat <<EOF

Uninstalled capsicum AppImage desktop integration.
User data (accounts in libsecret, settings, logs) was NOT removed.
See INSTALL.md for how to clear those if needed.
EOF
