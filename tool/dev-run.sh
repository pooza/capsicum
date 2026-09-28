#!/usr/bin/env bash
# debug で capsicum を動かす (#1179)。
#
#   secrets.env を読む → melos run build_runner → packages/capsicum で flutter run
#
# 手で打つと落としやすい 3 点をここで固定する（docs/dev-environment.md
# 「flutter run の実行手順」）。
#
# - ⚠⚠ RELAY_SECRET があれば必ず --dart-define で渡す。source しただけでは Dart に
#   届かず、プッシュ登録が 401 で落ちる。relay 側にはログが残らない (#994)
# - packages/capsicum で flutter run する。workspace 直下だと iOS が候補に出ない
# - ⚠ secrets.env が読めない / RELAY_SECRET が空でも**止めない**（#1180）。警告を
#   出して起動し、プッシュ通知だけ使えない状態にする。秘密を持てるのはメンテナ
#   だけなので、止めると外部の開発者がこの手順を使えない
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

# ⚠⚠ 秘密が無くても止めない（#1180）。RELAY_SECRET を持てるのはメンテナだけなので、
# 止めると外部の開発者はこの手順でアプリを動かせない。**無ければ警告だけ出して
# --dart-define を付けずに起動し、プッシュ通知だけ使えない状態にする。**
# ⚠ メンテナが Google ドライブのリンク切れに気付けるよう、警告は必ず出す。
if [ -r "$secrets" ]; then
  # shellcheck disable=SC1090
  source "$secrets"
fi
if [ ! -r "$secrets" ]; then
  echo "warning: $secrets が読めません（メンテナなら Google ドライブのリンク切れを疑う）" >&2
elif [ -z "${RELAY_SECRET:-}" ]; then
  echo "warning: $secrets に RELAY_SECRET がありません" >&2
fi
if [ -z "${RELAY_SECRET:-}" ]; then
  echo "warning: プッシュ通知は使えません（設定 → プッシュ通知の登録が 401 で落ちます）。他の機能は動きます" >&2
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
    # ⚠ 空文字での置換は全文字の間に挟まるので、秘密が無い回は素通しする。
    local line="$*"
    if [ -n "${RELAY_SECRET:-}" ]; then
      printf '%s\n' "${line//"$RELAY_SECRET"/<RELAY_SECRET>}"
    else
      printf '%s\n' "$line"
    fi
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
# ⚠ 秘密が無い回は --dart-define ごと落とす。空文字を焼き込むと、relay 側は
# 「値が違う」ではなく「署名が合わない」で落ちて原因が読みにくくなる。
if [ -n "${RELAY_SECRET:-}" ]; then
  run flutter run --dart-define=RELAY_SECRET="$RELAY_SECRET" ${flutter_args[@]+"${flutter_args[@]}"}
else
  run flutter run ${flutter_args[@]+"${flutter_args[@]}"}
fi
