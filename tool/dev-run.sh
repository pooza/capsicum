#!/usr/bin/env bash
# debug で capsicum を動かす (#1179)。
#
#   secrets.env を読む → melos run build_runner → packages/capsicum で flutter run
#
# 手で打つと落としやすい 3 点をここで固定する（docs/dev-environment.md
# 「flutter run の実行手順」）。
#
# - ⚠⚠ --dart-define=RELAY_SECRET を必ず付ける。source しただけでは Dart に
#   届かず、プッシュ登録が 401 で落ちる。relay 側にはログが残らない (#994)
# - packages/capsicum で flutter run する。workspace 直下だと iOS が候補に出ない
# - secrets.env が読めない / RELAY_SECRET が空なら止まる
#
# SENTRY_DSN は渡さない。渡すと開発中の例外が本番プロジェクトへ流れる。
#
# 使い方は -h。
#
# ⚠ macOS 標準の bash 3.2 でも動くように書く（配列の空展開・連想配列を使わない）。

set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: tool/dev-run.sh [-s] [-n] [flutter run の引数...]
  -s, --skip-build-runner  build_runner を飛ばす
  -n, --dry-run            実行せず、流すコマンドを表示する（秘密は伏せる）
例: tool/dev-run.sh -d macos
    tool/dev-run.sh -s -d emulator-5554
USAGE
}

skip_build_runner=0
dry_run=0
flutter_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -s | --skip-build-runner) skip_build_runner=1 ;;
    -n | --dry-run) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      flutter_args+=("$@")
      break
      ;;
    *) flutter_args+=("$1") ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
secrets="${CAPSICUM_SECRETS:-$HOME/.config/capsicum/secrets.env}"

if [ ! -r "$secrets" ]; then
  echo "error: $secrets が読めません（Google ドライブのリンク切れを疑う）" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$secrets"
if [ -z "${RELAY_SECRET:-}" ]; then
  echo "error: $secrets に RELAY_SECRET がありません（空のまま焼き込むとプッシュが 401 になる）" >&2
  exit 1
fi

# melos は Pub Cache の bin に入る。PATH 外だと melos run build_runner の中の
# melos 解決も失敗する (docs/dev-environment.md)。
case ":$PATH:" in
  *":$HOME/.pub-cache/bin:"*) ;;
  *) export PATH="$PATH:$HOME/.pub-cache/bin" ;;
esac

run() {
  if [ "$dry_run" -eq 1 ]; then
    # 秘密は伏せて表示する。sed だと値の中の記号を正規表現として読んでしまう。
    local line="$*"
    printf '%s\n' "${line//"$RELAY_SECRET"/<RELAY_SECRET>}"
  else
    "$@"
  fi
}

cd "$repo_root"
if [ "$skip_build_runner" -eq 0 ]; then
  run melos run build_runner
fi

cd "$repo_root/packages/capsicum"
[ "$dry_run" -eq 1 ] && echo "(cd packages/capsicum)"
# ${arr[@]+"${arr[@]}"}: bash 3.2 + set -u で空配列を展開すると落ちるための書き方。
run flutter run --dart-define=RELAY_SECRET="$RELAY_SECRET" ${flutter_args[@]+"${flutter_args[@]}"}
