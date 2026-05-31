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
# いない。
if [[ -f "$DESKTOP_ENTRY" ]]; then
  EXEC_LINE=$(grep -E "^Exec=" "$DESKTOP_ENTRY" | head -1 | sed -E "s|^Exec=||" || true)
  APPIMAGE_PATH="${EXEC_LINE% %U}"
  if [[ -f "$APPIMAGE_PATH" && "$APPIMAGE_PATH" == "$APPLICATIONS_DIR/"* ]]; then
    echo "==> Removing AppImage $APPIMAGE_PATH"
    rm -f "$APPIMAGE_PATH"
  fi
  echo "==> Removing desktop entry $DESKTOP_ENTRY"
  rm -f "$DESKTOP_ENTRY"
else
  echo "warn: desktop entry not found at $DESKTOP_ENTRY (already uninstalled?)" >&2
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
