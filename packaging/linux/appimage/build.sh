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
for cmd in linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool patchelf; do
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

# Flutter (sentry_flutter 同梱) の crashpad_handler は release bundle 段階で
# 既に execute bit が落ちている (`-rw-r--r--`)。実行権限がないと posix_spawn
# が EACCES で失敗し、Sentry の native crash dump 経路が起動できない (#496)。
# Flutter / sentry_flutter 側の packaging バグだが、こちらで chmod +x して
# 補正する。
if [ -f "$APPDIR/usr/bin/lib/crashpad_handler" ]; then
  chmod +x "$APPDIR/usr/bin/lib/crashpad_handler"
fi

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

# Flutter ビルドが生成する plugin .so の RUNPATH には build 時の絶対パス
# (例: /home/pooza/.../linux/flutter/ephemeral) が刻まれている。これは
# 開発機のローカルパス前提で、build マシン以外では解決に失敗する。
# linuxdeploy は usr/lib/ にコピーする plugin の RUNPATH を $ORIGIN に
# 直すが、usr/bin/lib/ の元ファイルはそのまま。AppImage 配布は usr/lib/
# 経由で動くため通常は問題にならないが、生 bundle (build/linux/x64/
# release/bundle/) を直接動かす経路で同じ .so をロードする場合に絶対
# パス RUNPATH が悪さをする。defensive な cleanup として元ファイルも
# $ORIGIN に揃えておく。
echo "==> Patching plugin RUNPATHs to \$ORIGIN (defensive)"
shopt -s nullglob
for so in "$APPDIR/usr/bin/lib/"*.so; do
  current_rpath=$(patchelf --print-rpath "$so" 2>/dev/null || true)
  # /home /Users /build は手元 / モデルケースの絶対パスを拾うために残し、
  # それ以外も含めた絶対パス全般 (CI runner の /__w/... や非標準 build dir
  # 等、未知の配置) を拾えるよう defensive に拡張 (#514)。
  # $ORIGIN はもとから相対指定なので case で除外すればよい。
  case "$current_rpath" in
    '$ORIGIN'|'$ORIGIN'/*|'')
      ;;
    /*)
      patchelf --set-rpath '$ORIGIN' "$so"
      echo "  patched $(basename "$so") (was: $current_rpath)"
      ;;
  esac
done
shopt -u nullglob

echo "==> Bundling GTK and dependencies via linuxdeploy (no seal)"
mkdir -p "$DIST_DIR"
cd "$DIST_DIR"

# linuxdeploy で AppDir をバンドルだけ行い、--output appimage は付けない。
# AppImage seal は appimagetool で別段 (#496)。
# 理由: seal 前に AppRun を差し替えて stderr/stdout をログファイルに残す
# 必要があるため (Linux で AppImage をデスクトップから起動すると stderr が
# 捨てられ、native crash 後に手がかりが残らない問題への対応)。
DEPLOY_GTK_VERSION=3 \
linuxdeploy \
  --appdir "$APPDIR" \
  --plugin gtk \
  --desktop-file "$APPDIR/usr/share/applications/$APP_ID.desktop" \
  --icon-file "$APPDIR/$APP_ID.png"

# bundled libibus を除去する (#532)。
#
# 経緯 (v1.24.1 → v1.24.2 訂正):
# v1.24.1 リリース時は「linuxdeploy-plugin-gtk が ldd 経由で libibus-1.0.so.5
# をバンドルしホスト ibus-daemon との DBus protocol drift を起こしている」
# という仮説で本 rm を追加した。しかし真因は別で、CI runner (ubuntu-22.04)
# に ibus-gtk3 がインストールされておらず im-ibus.so 自体が host に存在せず
# AppImage に bundle されていない、つまり ibus 経路が完全に欠落していたこと
# だった。v1.24.2 で workflow に ibus-gtk3 を追加して im-ibus.so が bundle
# されるようにした結果、im-ibus.so / libibus-1.0.so.5 がどちらも bundle される
# 状態になる。
#
# その上で libibus 本体は AppDir から除去し、ホスト側 libibus
# (/lib/x86_64-linux-gnu/libibus-1.0.so.5) を ld.so.cache 経由で引かせる。
# im-ibus.so の DT_NEEDED は libibus-1.0.so.5 で、RUNPATH/RPATH に AppDir が
# 無くても解決される。host ibus-daemon と libibus の version を必ず一致させる
# ことで protocol drift リスクを最小化する (Flatpak が同じ方針 = runtime 提供
# の libibus + ibus-daemon 揃え、で問題なく動いている)。
#
# pooza の手元 (Debian 13 + ibus-gtk3 既導入) で本 rm を入れずに ibus 経路が
# 動いていたのは、Debian の ibus と AppImage 内 libibus の API が偶然一致して
# いたから。他環境では未保証なので本 rm は v1.24.2 でも残す。
echo "==> Removing bundled libibus to avoid #532 host drift risk"
rm -fv "$APPDIR/usr/lib/libibus-1.0.so."* 2>&1 | sed 's/^/  /'

echo "==> Replacing AppRun with logging wrapper (#496)"
# linuxdeploy が生成する AppRun は exec で wrapped を呼ぶだけで、stderr が
# ターミナル外起動 (.desktop / Activities) では失われる。AppRun.wrapped を
# 経由しつつ tee でログファイルに残す版に差し替える。
cat > "$APPDIR/AppRun" <<'APPRUN_EOF'
#! /usr/bin/env bash

# capsicum AppImage launcher (auto-generated by build.sh)
# stderr/stdout を ~/.local/share/capsicum/logs/ に保存する。
# native crash (GTK/GLX 等) 含めて起動直前までの記録を残すため、
# tee で並列に書き出す。

set -e

this_dir="$(readlink -f "$(dirname "$0")")"

# crashpad_handler の execute bit が落ちていると Sentry に native crash dump
# が届かなくなる (build.sh 側で chmod +x しているが、Flutter / sentry_flutter
# の上流挙動変更や手動 untar 等で bit が落ちうる)。AppRun のログに警告を残し、
# pooza に送られる診断情報から検知できるようにする (#510)。
crashpad_handler="$this_dir/usr/bin/lib/crashpad_handler"
if [ -e "$crashpad_handler" ] && [ ! -x "$crashpad_handler" ]; then
  echo "WARN: crashpad_handler not executable: $crashpad_handler" >&2
fi

source "$this_dir"/apprun-hooks/"linuxdeploy-plugin-gtk.sh"

LOG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsicum/logs"
# tee 経由で機微情報 (debugPrint・stderr スタック等) が混じり得るため、
# ディレクトリと以降に作るログファイルを 700/600 に制限する。
umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/capsicum-$(date +%Y%m%d-%H%M%S)-$$.log"

# 古いログをローテーション (最新 10 件のみ残す)
ls -t "$LOG_DIR"/capsicum-*.log 2>/dev/null | tail -n +11 | xargs -r rm -- 2>/dev/null || true

# tee 経由になるとデフォルトでフルバッファリング (4KB+ chunk) になり、
# native crash 直前の行が flush 前で失われる。stdbuf -oL -eL で line buffer
# 化し、crash 時に直前の出力までログに残すよう保証する。
# pipefail を切って tee の exit code を伝搬しないようにする。
set +e
stdbuf -oL -eL "$this_dir"/AppRun.wrapped "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
APPRUN_EOF
chmod +x "$APPDIR/AppRun"

echo "==> Sealing AppImage with appimagetool"
FINAL="$DIST_DIR/${APP_NAME}-${VERSION}-x86_64.AppImage"
ARCH=x86_64 appimagetool "$APPDIR" "$FINAL"

echo "==> Built: $FINAL"
ls -lh "$FINAL"
