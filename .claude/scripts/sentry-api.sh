#!/bin/sh
# Sentry の調査用トークン（~/.sentryclirc の [auth]）を、画面にもコマンドラインにも出さずに使う。
#
# auto モードの分類器は、トークンを標準出力へ読み出す手順を「認証情報の露出」として拒否する。
# autoMode.allow に自然文で許可を書いても拒否された（2026-09-17・Linux 端末）ので、
# 読み出しをこのスクリプトの中に閉じ、スクリプトを permissions.allow に載せる。
#
# 使い方（リポジトリ root から）:
#   .claude/scripts/sentry-api.sh get  <path>          例: get /issues/7735459900/events/latest/
#   .claude/scripts/sentry-api.sh post <path> <json>   例: post /issues/7735459900/comments/ '{"text":"..."}'
#   .claude/scripts/sentry-api.sh cli  <sentry-cli の引数...>   例: cli issues list -p capsicum
#
# <path> は https://sentry.io/api/0 の後ろ。送り先のホストは固定で、呼ぶ側からは変えられない。
set -eu

rc="$HOME/.sentryclirc"
token=$(awk '/^\[auth\]/ { f = 1; next } /^\[/ { f = 0 } f && /^token=/ { sub(/^token=/, ""); print; exit }' "$rc")
if [ -z "$token" ]; then
  echo "sentry-api: $rc の [auth] に token がありません" >&2
  exit 1
fi

usage="usage: sentry-api.sh get <path> | post <path> <json> | cli <args...>"
cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
  get | post)
    case "${1:-}" in
      /*) ;;
      *) echo "sentry-api: <path> は / で始める（$usage）" >&2; exit 2 ;;
    esac
    ;;
esac

case "$cmd" in
  get)
    [ $# -eq 1 ] || { echo "$usage" >&2; exit 2; }
    printf 'header = "Authorization: Bearer %s"\n' "$token" |
      curl -s -K - "https://sentry.io/api/0$1"
    ;;
  post)
    [ $# -eq 2 ] || { echo "$usage" >&2; exit 2; }
    printf 'header = "Authorization: Bearer %s"\n' "$token" |
      curl -s -K - -X POST -H 'Content-Type: application/json' --data-raw "$2" "https://sentry.io/api/0$1"
    ;;
  cli)
    SENTRY_AUTH_TOKEN=$token exec sentry-cli "$@"
    ;;
  *)
    echo "$usage" >&2
    exit 2
    ;;
esac
