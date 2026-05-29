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
  --dart-define=SENTRY_ENV=production \
  --dart-define=DIRECT_CHANNEL=true

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
  # patchelf --print-rpath は `/path1:/path2` のようなコロン区切り複合
  # RUNPATH もそのまま返す。絶対パス全般を `$ORIGIN` 一発に書き換える
  # 旧実装 (#514) は、`$ORIGIN:/usr/lib/...` のような複合エントリで
  # 正当な相対部分まで失っていた (#527)。コロン区切りで分割し、各
  # セグメント単位で絶対パス → `$ORIGIN` に丸めて再結合する。
  if [ -z "$current_rpath" ]; then
    continue
  fi
  new_rpath=""
  changed=0
  IFS=':' read -ra rpath_segments <<< "$current_rpath"
  for seg in "${rpath_segments[@]}"; do
    case "$seg" in
      /*)
        seg='$ORIGIN'
        changed=1
        ;;
    esac
    new_rpath="${new_rpath:+$new_rpath:}$seg"
  done
  if [ "$changed" -eq 1 ]; then
    patchelf --set-rpath "$new_rpath" "$so"
    echo "  patched $(basename "$so") (was: $current_rpath)"
  fi
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

# libibus-1.0.so.5 を AppDir に明示コピーする (#532)。
#
# 経緯 (v1.24.0 〜 v1.24.3 真因解明):
# linuxdeploy-plugin-gtk は ldd 経由で im-ibus.so を AppImage に bundle するが、
# その依存 libibus-1.0.so.5 は (理由不明だが) bundle しない。host 側 libibus
# を ld.so.cache 経由で引かせると、新しい host libibus が要求する GLib symbol
# (g_task_set_static_name 等。GLib 2.76 以降) が bundled GLib (build host
# ubuntu-22.04 = GLib 2.72) で解決できず、IM context 'ibus' のロードに失敗
# する。具体例: Debian 13 / GLib 2.84 系の host で `Loading IM context type
# 'ibus' failed` + `undefined symbol: g_task_set_static_name` が stderr に出る。
#
# v1.24.0 / v1.24.1 / v1.24.2 まではこの mismatch を見逃しており、当初は
# 「bundled libibus と host ibus-daemon の DBus protocol drift」「im-ibus.so
# 不足」と二段階の誤診を経た。真因は GLib version mismatch。
#
# 対処として AppImage 内に libibus を明示同梱する。bundled GLib と同世代の
# libibus (build host = ubuntu-22.04 の libibus-1.0-5) が入るため symbol
# resolution は成立する。host ibus-daemon との DBus protocol は libibus 1.5
# 系で安定しており、Flatpak (org.gnome.Platform 提供 libibus + host ibus-daemon)
# が問題なく動いていることから drift リスクは小さいと判断。
echo "==> Bundling libibus into AppDir (host libibus 経由の GLib symbol mismatch を避ける)"
HOST_LIBIBUS_DIR=/usr/lib/x86_64-linux-gnu
if compgen -G "$HOST_LIBIBUS_DIR/libibus-1.0.so.*" > /dev/null; then
  cp -av "$HOST_LIBIBUS_DIR"/libibus-1.0.so.* "$APPDIR/usr/lib/" 2>&1 | sed 's/^/  /'
else
  echo "ERROR: $HOST_LIBIBUS_DIR/libibus-1.0.so.* not found. Install libibus-1.0-5 (ibus-gtk3 brings it)." >&2
  exit 1
fi

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

# v1.24.1 → v1.24.2 で CI runner image の構成変化により im-ibus.so が
# 静かに同梱されなくなる事故があった。回帰防止のため、GTK IM module の
# bundle と immodules.cache 登録を mechanical に検証する (#536)。
# fcitx5 / uim は best-effort (動作未検証) だが、CI assertion 自体は
# 同等にかける。
echo "==> Verifying GTK IM module bundling (regression guard, #536)"
IM_DIR="$APPDIR/usr/lib/gtk-3.0/3.0.0/immodules"
IM_CACHE="$APPDIR/usr/lib/gtk-3.0/3.0.0/immodules.cache"
if [ ! -f "$IM_CACHE" ]; then
  echo "ERROR: immodules.cache not found at $IM_CACHE" >&2
  exit 1
fi
for module in im-ibus.so im-fcitx5.so im-uim.so; do
  if [ ! -f "$IM_DIR/$module" ]; then
    echo "ERROR: $module not bundled at $IM_DIR/$module" >&2
    exit 1
  fi
  # immodules.cache のエントリは linuxdeploy-plugin-gtk が basename へ正規化する
  # (`sed -i "s|.../immodules/||g"`) ため通常は `"im-ibus.so"` 形式になるが、
  # host の GTK lib path が標準と異なって sed が空振りした場合は
  # `"/usr/lib/.../im-ibus.so"` のパス形式で残る。どちらでも検出できるよう
  # 両方の prefix (`"` / `/`) を許す fixed-string 検索にする (#539 Codex P1)。
  if ! grep -qF -e "\"$module\"" -e "/$module\"" "$IM_CACHE"; then
    echo "ERROR: $module not registered in immodules.cache" >&2
    exit 1
  fi
  echo "  OK: $module bundled and registered"
done

echo "==> Sealing AppImage with appimagetool"
FINAL="$DIST_DIR/${APP_NAME}-${VERSION}-x86_64.AppImage"
ARCH=x86_64 appimagetool "$APPDIR" "$FINAL"

echo "==> Built: $FINAL"
ls -lh "$FINAL"
