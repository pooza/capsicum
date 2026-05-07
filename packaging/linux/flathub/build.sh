#!/usr/bin/env bash
# capsicum Flatpak local build script (Phase 3: ローカル動作確認用)
#
# 配布版 (Flathub 提出用) のオフラインビルド対応 manifest は
# Phase 5a で別途作成する。本スクリプトはネットワーク有り環境で
# 開発機に Flatpak を組み立てて install + flatpak run までで起動を
# 確認するためのもの。
#
# 前提:
#   sudo apt install -y flatpak flatpak-builder
#   flatpak remote-add --user --if-not-exists flathub \
#     https://flathub.org/repo/flathub.flatpakrepo
#   flatpak install --user flathub org.gnome.Platform//49 org.gnome.Sdk//49

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
APP_DIR="$REPO_ROOT/packages/capsicum"
BUILD_DIR="$REPO_ROOT/build/linux/flatpak"
APP_ID="net.shrieker.capsicum"

# pubspec の version 1.24.0+60 から 1.24.0 を取得
VERSION=$(awk -F'[ +]' '/^version:/{print $2; exit}' "$APP_DIR/pubspec.yaml")

for cmd in flatpak flatpak-builder; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd not in PATH" >&2
    exit 1
  fi
done

# secrets.env が有れば --dart-define で注入
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

echo "==> Running flatpak-builder"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# --user で個人 Flatpak ストアにインストール、--force-clean でビルド
# ディレクトリを毎回クリア。
flatpak-builder \
  --user \
  --install \
  --force-clean \
  --install-deps-from=flathub \
  build \
  "$SCRIPT_DIR/$APP_ID.yml"

echo "==> Built and installed: $APP_ID"
echo "Run with: flatpak run --user $APP_ID"
