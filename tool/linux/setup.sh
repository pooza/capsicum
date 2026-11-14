#!/usr/bin/env bash
# Linux の開発・検証機の立ち上げ (足りないものだけを入れる・何度走らせてもよい)。
#
# 人の手が要るのは、最初の sudo のパスワード 1 回と、(GH_TOKEN が無ければ)
# GitHub のログインだけ。それ以降の apt は Claude が確認なしで回せるように、
# apt-get をパスワードなしにする sudoers を置く (2026-11-14 pooza 了承)。
#
# 使い方:
#   tool/linux/setup.sh
#
# やること:
#   1. apt のパッケージ (一覧は packages.sh) と ja_JP.UTF-8 のロケール
#   2. /etc/sudoers.d/capsicum-apt (この利用者の apt / apt-get をパスワードなしに)
#   3. GitHub のログイン (secrets.env の GH_TOKEN があればそれで・無ければブラウザ)
#      と、git の github.com の資格情報を gh に任せる設定
#   4. ~/repos への関連リポジトリの clone
#   5. GNOME の portal で、サンドボックス外のアプリに画面の撮影を許す
#      (Wayland で Claude が画面を確かめるため)
#   最後に doctor.sh で点検する。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=packages.sh
source "$ROOT/tool/linux/packages.sh"
SECRETS="${CAPSICUM_SECRETS:-$HOME/.config/capsicum/secrets.env}"

step() { printf '\n==> %s\n' "$1"; }

step "sudo (the password is asked only here)"
sudo -v

step "apt packages"
sudo apt-get update -q
sudo apt-get install -y -q "${APT_PACKAGES[@]}"
if ! locale -a | grep -qi '^ja_JP\.utf-\?8$'; then
  sudo locale-gen ja_JP.UTF-8
fi

step "sudoers: apt / apt-get without a password for $USER"
tmp=$(mktemp)
printf '%s ALL=(root) NOPASSWD: /usr/bin/apt, /usr/bin/apt-get\n' "$USER" > "$tmp"
sudo visudo -cf "$tmp" >/dev/null
sudo install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/$SUDOERS_NAME"
rm -f "$tmp"

step "GitHub"
if gh auth status >/dev/null 2>&1; then
  echo "already logged in"
else
  token=""
  if [[ -f "$SECRETS" ]]; then
    token=$(sed -n -E 's/^(export +)?GH_TOKEN=["'\'']?([^"'\'']*)["'\'']?$/\2/p' "$SECRETS" | head -1)
  fi
  if [[ -n "$token" ]]; then
    echo "logging in with GH_TOKEN from $SECRETS"
    gh auth login -h github.com -p https --with-token <<< "$token"
  else
    cat <<'EOF'
GH_TOKEN is not in secrets.env, so log in with the browser:
  1. Note the one-time code that appears below.
  2. Press Enter here (gh waits for Enter before it starts listening;
     a warning that it cannot open a browser is fine).
  3. On any device, open https://github.com/login/device and enter the code.
EOF
    gh auth login -h github.com -p https -w
  fi
fi
gh auth setup-git -h github.com

step "related repositories in ~/repos"
mkdir -p "$HOME/repos"
for r in "${RELATED_REPOS[@]}"; do
  if [[ -d "$HOME/repos/$r/.git" ]]; then
    echo "$r: present"
  else
    gh repo clone "pooza/$r" "$HOME/repos/$r"
  fi
done

step "screenshots via the portal (GNOME)"
if command -v gnome-shell >/dev/null; then
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
  if gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
       --object-path /org/freedesktop/impl/portal/PermissionStore \
       --method org.freedesktop.impl.portal.PermissionStore.SetPermission \
       screenshot true screenshot '' "['yes']" >/dev/null; then
    echo "allowed"
  else
    echo "warn: could not reach the desktop session bus; log in on the screen and re-run" >&2
  fi
else
  echo "not GNOME; skipped"
fi

step "check"
"$ROOT/tool/linux/doctor.sh" || true
