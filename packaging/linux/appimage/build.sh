#!/usr/bin/env bash
# capsicum AppImage build script (Phase 2: ローカル動作確認用)
#
# 配布用 portable AppImage は Phase 4 (#424) の GitHub Actions Ubuntu runner
# で生成する。本スクリプトは開発機 (Debian 13 / Ubuntu 24.04 等) でローカル
# に AppImage を組み立てて起動確認するためのもの。生成された AppImage は
# build した OS と glibc 互換性のあるディストロでしか動かない。
#
# 必要ツール (~/.local/bin に配置):
#   - linuxdeploy (https://github.com/linuxdeploy/linuxdeploy)
#   - linuxdeploy-plugin-gtk.sh (https://github.com/linuxdeploy/linuxdeploy-plugin-gtk)
#   - appimagetool (https://github.com/AppImage/appimagetool)
#
# 使い方: bash packaging/linux/appimage/build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
APP_DIR="$REPO_ROOT/packages/capsicum"
SHARED_DIR="$SCRIPT_DIR/../shared"
DIST_DIR="$REPO_ROOT/build/linux/dist"
APP_ID="net.shrieker.capsicum"
APP_NAME="capsicum"

# pubspec.yaml の `version: 1.24.0+60` から 1.24.0 部分を取得
VERSION=$(awk -F'[ +]' '/^version:/{print $2; exit}' "$APP_DIR/pubspec.yaml")
if [ -z "$VERSION" ]; then
  echo "ERROR: failed to read version from $APP_DIR/pubspec.yaml" >&2
  exit 1
fi

# 必要ツールの存在確認
for cmd in linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd not found in PATH (~/.local/bin/ に配置する想定)" >&2
    exit 1
  fi
done

# Sentry / capsicum-relay 連携は ~/.config/capsicum/secrets.env から取得 (任意)
SENTRY_DSN_VAL=""
RELAY_SECRET_VAL=""
if [ -f "$HOME/.config/capsicum/secrets.env" ]; then
  # shellcheck disable=SC1091
  set -a
  . "$HOME/.config/capsicum/secrets.env"
  set +a
  SENTRY_DSN_VAL="${SENTRY_DSN:-}"
  RELAY_SECRET_VAL="${RELAY_SECRET:-}"
fi

echo "==> Building Flutter Linux release (version: $VERSION)"
cd "$APP_DIR"
flutter build linux --release \
  ${SENTRY_DSN_VAL:+--dart-define=SENTRY_DSN="$SENTRY_DSN_VAL"} \
  ${RELAY_SECRET_VAL:+--dart-define=RELAY_SECRET="$RELAY_SECRET_VAL"} \
  --dart-define=SENTRY_ENV=production

BUNDLE_DIR="$APP_DIR/build/linux/x64/release/bundle"
APPDIR="$APP_DIR/build/linux/AppDir"

echo "==> Constructing AppDir at $APPDIR"
rm -rf "$APPDIR"
mkdir -p \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/metainfo"

# Flutter のバンドルは executable の隣に data/ と lib/ を要求する。
# usr/bin/ 配下にそのまま配置することで Flutter のパス解決が機能する。
cp -r "$BUNDLE_DIR"/* "$APPDIR/usr/bin/"

cp "$SHARED_DIR/$APP_ID.desktop" "$APPDIR/usr/share/applications/"
cp "$SHARED_DIR/$APP_ID.metainfo.xml" "$APPDIR/usr/share/metainfo/"

# Icons: macOS の AppIcon.appiconset を流用 (16〜1024 全サイズ)
ICON_SRC="$APP_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 64 128 256 512 1024; do
  ICON_DST="$APPDIR/usr/share/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$ICON_DST"
  cp "$ICON_SRC/app_icon_${size}.png" "$ICON_DST/$APP_ID.png"
done

# linuxdeploy は AppDir 直下のアイコンも要求する
cp "$ICON_SRC/app_icon_256.png" "$APPDIR/$APP_ID.png"

echo "==> Bundling GTK and dependencies via linuxdeploy"
mkdir -p "$DIST_DIR"
cd "$DIST_DIR"

DEPLOY_GTK_VERSION=3 \
linuxdeploy \
  --appdir "$APPDIR" \
  --plugin gtk \
  --output appimage \
  --desktop-file "$APPDIR/usr/share/applications/$APP_ID.desktop" \
  --icon-file "$APPDIR/$APP_ID.png"

# linuxdeploy が生成する AppImage 名は capsicum-<arch>.AppImage
# 命名規則を capsicum-<version>-<arch>.AppImage に揃える
GENERATED=$(ls "$DIST_DIR"/*.AppImage 2>/dev/null | head -1 || true)
if [ -z "$GENERATED" ]; then
  echo "ERROR: linuxdeploy did not produce an AppImage" >&2
  exit 1
fi
FINAL="$DIST_DIR/${APP_NAME}-${VERSION}-x86_64.AppImage"
if [ "$GENERATED" != "$FINAL" ]; then
  mv "$GENERATED" "$FINAL"
fi

echo "==> Built: $FINAL"
ls -lh "$FINAL"
