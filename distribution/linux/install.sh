#!/usr/bin/env bash
# capsicum AppImage デスクトップ統合インストール (#640)
#
# 配布対象は AppImage 単独 (Flathub 断念 #604) のため、放置するとアプリ
# メニューに登録されず GUI ランチャーから起動できない。AppImageLauncher を
# 入れていない環境向けに、最低限のメニュー / アイコン登録を一発で行う。
#
# 使い方:
#   ./install.sh /path/to/capsicum-x.y.z-x86_64.AppImage
#   ./install.sh                # 最新 Release を落として入れる
#   ./install.sh --force        # 落としたものの照合が合わなくても進める (#1384)
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
RAW_BASE="https://raw.githubusercontent.com/$REPO/main/distribution/linux"

usage() {
  cat <<EOF
Usage: $0 [--force] [path-to-capsicum-*.AppImage]

With NO path, downloads the latest capsicum AppImage from GitHub
Releases and installs it (designed for \`curl … | bash\` one-liner use).
The downloaded file is checked against the SHA-256 digest published
with the release; if it does not match, nothing is installed and the
likely causes (curl / wget config files, proxy / certificate variables)
are listed.
With a path, installs that local AppImage instead (no digest check).

Options:
  --force     Install even if the digest check fails (a warning is
              printed). From the one-liner:
                curl -fsSL https://capsicum.shrieker.net/install.sh | bash -s -- --force
  -h, --help  Show this help.

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

# 取得に失敗した / 落としたものが壊れていたときに、原因の候補を挙げる (#1384)。
# 利用者の設定は尊重し (`curl -q` で .curlrc を無視したりはしない)、何が
# 効いていそうかを知らせるだけにする。環境変数は名前だけを出し、値は出さない
# (プロキシの URL に認証情報が入っていることがあるため)。
explain_fetch_problem() {
  local found=0 f name
  local -a files=()
  if command -v curl >/dev/null; then
    [[ -n "${CURL_HOME:-}" ]] && files+=("$CURL_HOME/.curlrc")
    [[ -n "${XDG_CONFIG_HOME:-}" ]] && files+=("$XDG_CONFIG_HOME/.curlrc")
    files+=("$HOME/.curlrc")
  elif command -v wget >/dev/null; then
    [[ -n "${WGETRC:-}" ]] && files+=("$WGETRC")
    files+=("$HOME/.wgetrc")
  fi
  echo "       Possible causes:" >&2
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then
      echo "         - config file: $f (options in it are applied to every download)" >&2
      found=1
    fi
  done
  for name in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY \
              CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR; do
    if [[ -n "${!name:-}" ]]; then
      echo "         - environment variable: $name is set" >&2
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "         - none found locally; this may be a network problem or a" >&2
    echo "           problem on the distribution side. Please try again later." >&2
  fi
  echo "       See $RAW_BASE/INSTALL.md for manual steps." >&2
}

# Release の JSON から、指定した asset の digest (`sha256:...`) を取り出す。
# 利用者の環境に jq があるとは限らないので grep / awk で読む。整形の有無
# (改行・空白) に依存しないよう、"name" / "digest" / "browser_download_url"
# の文字列値だけを出現順に拾い、asset の "name" ごとに digest を区切って、
# URL が一致した asset の digest を返す (digest は asset 内で URL より前に来る)。
# digest が無い・null のときは空を返す。
release_asset_digest() {
  local json="$1" url="$2"
  grep -oE '"(name|digest|browser_download_url)"[[:space:]]*:[[:space:]]*"[^"]*"' <<< "$json" \
    | awk -v want="$url" '
        {
          key = $0; sub(/^"/, "", key); sub(/".*/, "", key)
          val = $0; sub(/"[[:space:]]*$/, "", val); sub(/.*"/, "", val)
          if (key == "name") { digest = "" }
          else if (key == "digest") { digest = val }
          else if (key == "browser_download_url" && val == want) { print digest; exit }
        }' || true
}

sha256_of() {
  local file="$1" sum
  if command -v sha256sum >/dev/null; then
    read -r sum _ < <(sha256sum "$file")
  elif command -v shasum >/dev/null; then
    read -r sum _ < <(shasum -a 256 "$file")
  else
    return 1
  fi
  printf '%s\n' "$sum"
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

# 引数: オプション (--force / --help) と、任意の AppImage のパス 1 つ (#1384)。
FORCE=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --force)
      FORCE=1
      ;;
    --)
      shift
      POSITIONAL+=("$@")
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      ;;
  esac
  shift
done

if [[ ${#POSITIONAL[@]} -gt 1 ]]; then
  usage >&2
  exit 1
fi

if [[ ${#POSITIONAL[@]} -eq 1 ]]; then
  # ローカル指定モード: 既存の使い方 (引数で AppImage パスを渡す)。
  # 照合する digest が無いので確かめない (#1384)。
  SRC="${POSITIONAL[0]}"
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
  if ! RELEASE_JSON=$(fetch_stdout "$LATEST_API"); then
    echo "error: could not fetch the release information from $LATEST_API" >&2
    explain_fetch_problem
    exit 1
  fi
  # grep -m1 は 1 件目で終了するため、パイプで流し込むと書き手が SIGPIPE で
  # 落ちて pipefail に引っかかる (#1036)。ここは末尾の `|| true` がたまたま
  # 打ち消していたが、依存する理由がないので herestring にする。
  DOWNLOAD_URL=$(grep -m1 -oE 'https://[^"]+-x86_64\.AppImage' <<< "$RELEASE_JSON" || true)
  if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "error: could not find an x86_64 AppImage asset in the latest release" >&2
    explain_fetch_problem
    exit 1
  fi
  EXPECTED_DIGEST=$(release_asset_digest "$RELEASE_JSON" "$DOWNLOAD_URL")
  DL_DIR=$(mktemp -d -t capsicum-download-XXXXXX)
  CLEANUP_DIRS+=("$DL_DIR")
  SRC="$DL_DIR/$(basename "$DOWNLOAD_URL")"
  echo "==> Downloading $(basename "$DOWNLOAD_URL")"
  if ! download_to "$DOWNLOAD_URL" "$SRC"; then
    echo "error: could not download $DOWNLOAD_URL" >&2
    explain_fetch_problem
    exit 1
  fi

  # 落としたものを、Release が公開している digest と照合する (#1384)。
  # 合わなければ置かずに止める (壊れたファイルを ~/Applications/ に置いて
  # メニューに登録してしまわないため)。--force なら警告だけで進む。
  if [[ "$EXPECTED_DIGEST" != sha256:* ]]; then
    echo "warn: the release does not publish a SHA-256 digest for this file; skipping the check" >&2
  elif ! ACTUAL_SUM=$(sha256_of "$SRC"); then
    echo "warn: neither sha256sum nor shasum is available; skipping the digest check" >&2
  elif [[ "sha256:$ACTUAL_SUM" == "$EXPECTED_DIGEST" ]]; then
    echo "==> Verified SHA-256 digest"
  else
    echo "error: the downloaded file does not match the published digest" >&2
    echo "       expected: $EXPECTED_DIGEST" >&2
    echo "       actual:   sha256:$ACTUAL_SUM" >&2
    explain_fetch_problem
    if [[ "$FORCE" -eq 1 ]]; then
      echo "warn: --force was given; installing the unverified file anyway" >&2
    else
      echo "       Nothing was installed. To install anyway, re-run with --force:" >&2
      if command -v curl >/dev/null; then
        echo "         curl -fsSL https://capsicum.shrieker.net/install.sh | bash -s -- --force" >&2
      else
        echo "         wget -qO- https://capsicum.shrieker.net/install.sh | bash -s -- --force" >&2
      fi
      exit 1
    fi
  fi
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

# 展開の前に、AppImage (type 2) の印を確かめる (#1384)。先頭が ELF で、
# オフセット 8 に "AI" + 0x02 がある。--force で照合を飛ばしても、ここは
# 飛ばさない: 壊れたファイル (ヘッダーの混入・プロキシの HTML など) を実行
# すると、ELF でないものはシェルが台本として読んでしまうため。
MAGIC=$(od -An -tx1 -N11 "$SRC" | tr -d ' \n')
if [[ "${MAGIC:0:8}" != "7f454c46" || "${MAGIC:16:6}" != "414902" ]]; then
  echo "error: $SRC is not an AppImage (the file is probably corrupted)" >&2
  if [[ ${#POSITIONAL[@]} -eq 0 ]]; then
    explain_fetch_problem
  fi
  echo "       Nothing was installed." >&2
  exit 1
fi

# AppImage の中身 (.desktop / hicolor アイコン) を一時ディレクトリに展開
# して再利用する。リポジトリのファイル構成を仮定しないので、AppImage 単独
# + install.sh だけで動く。⚠ ~/Applications へ移す前に展開する (#1384):
# 展開できないものを置いて、安定 symlink をそこへ向けないため。
EXTRACT_DIR=$(mktemp -d -t capsicum-install-XXXXXX)
CLEANUP_DIRS+=("$EXTRACT_DIR")
# pushd で移動するので、相対パスで渡されたときに備えて絶対パスにする。
SRC_ABS="$(cd "$(dirname "$SRC")" && pwd)/$FILENAME"

echo "==> Extracting AppImage payload to $EXTRACT_DIR"
pushd "$EXTRACT_DIR" >/dev/null
if ! "$SRC_ABS" --appimage-extract >"$EXTRACT_DIR/extract.log" 2>&1; then
  popd >/dev/null
  echo "error: could not extract $SRC (the file may be corrupted)" >&2
  tail -n 5 "$EXTRACT_DIR/extract.log" >&2 || true
  echo "       Nothing was installed." >&2
  exit 1
fi
popd >/dev/null

SQUASH="$EXTRACT_DIR/squashfs-root"
SRC_DESKTOP="$SQUASH/usr/share/applications/$APP_ID.desktop"
SRC_ICON_BASE="$SQUASH/usr/share/icons/hicolor"

if [[ ! -f "$SRC_DESKTOP" ]]; then
  echo "error: .desktop entry not found in AppImage at $SRC_DESKTOP" >&2
  exit 1
fi

mkdir -p "$APPLICATIONS_DIR"
DEST="$APPLICATIONS_DIR/$FILENAME"
if [[ "$SRC" != "$DEST" ]]; then
  echo "==> Installing AppImage to $DEST"
  mv -f "$SRC" "$DEST"
fi
chmod +x "$DEST"

# バージョンを跨いで安定したパスでアプリを指す symlink (#707)。.desktop の
# Exec はこの symlink を指すので、新バージョン導入で AppImage のファイル名が
# 変わっても、アプリメニューの「お気に入り」や手製の .desktop ランチャーが
# 壊れない (旧来は Exec がバージョン付き AppImage を直接指していた)。
STABLE_LINK="$APPLICATIONS_DIR/$APP_NAME"
ln -sfn "$DEST" "$STABLE_LINK"

# 旧バージョンの掃除。~/Applications はインストーラ管理下で、参照は常に
# 安定 symlink (=最新) に向くため、旧 AppImage は誰も参照しないゴミになる。
# 放置すると溜まる一方なので、最新 + 直前 1 世代だけ残して古いものを消す。
# 削除対象は自前の命名 (capsicum-*-x86_64.AppImage) に厳密一致する「実
# ファイル」だけ。今入れた実体 ($DEST) / symlink / 他アプリの AppImage には
# 触れない。起動中の旧 AppImage を消しても Linux では inode がプロセス終了
# まで残るので実行中プロセスは壊れない。
KEEP=2
prune_old_appimages() {
  local all keep f
  # バージョン昇順 (sort -V) で並べたファイル名一覧 (実ファイルのみ)。
  all=$(find "$APPLICATIONS_DIR" -maxdepth 1 -type f \
        -name 'capsicum-*-x86_64.AppImage' -printf '%f\n' | sort -V)
  [[ -z "$all" ]] && return 0
  # 残すのは「新しい方 KEEP 件」+「今入れた実体 ($FILENAME)」。後者は世代数に
  # 関わらず必ず保護する (ローカル指定で旧バージョンを入れ直したケースでも
  # 消さないため)。連想配列を避け、改行区切りの keep リストへの完全一致
  # (grep -xF) で判定する (bash 3.2 でも動く)。
  keep=$(printf '%s\n' "$all" | tail -n "$KEEP")
  keep=$(printf '%s\n%s\n' "$keep" "$FILENAME")
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # ⚠ `printf ... | grep -q` にしないこと (#1036)。grep -q はマッチした時点で
    # 終了するので、後ろにデータが残っていると printf が SIGPIPE で落ち、
    # pipefail がパイプライン全体を失敗にする。すると `!` が反転して
    # 「keep に無い」と判定され、**残すべき AppImage を rm する**。
    # herestring なら一時ファイル経由なので書き手が落ちない。
    if ! grep -qxF -- "$f" <<< "$keep"; then
      echo "==> Removing old AppImage $APPLICATIONS_DIR/$f"
      rm -f "$APPLICATIONS_DIR/$f"
    fi
  done <<< "$all"
}
prune_old_appimages

mkdir -p "$DESKTOP_DIR"
DEST_DESKTOP="$DESKTOP_DIR/$APP_ID.desktop"
# Exec は元の `capsicum %U` (= $PATH 解決前提) のままだとランチャーから
# 起動できないので、安定 symlink ($STABLE_LINK) を絶対パスで指す (#707)。
# AppImage 内に StartupWMClass / Icon は既に書かれているのでそれ以外は
# そのまま流す。
echo "==> Writing $DEST_DESKTOP"
sed -E "s|^Exec=.*|Exec=$STABLE_LINK %U|" "$SRC_DESKTOP" > "$DEST_DESKTOP"

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
