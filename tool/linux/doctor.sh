#!/usr/bin/env bash
# Linux の開発・検証機の点検 (何も変えない)。
#
# 着いた端末で最初に 1 回走らせ、足りないものを全部まとめて出す。手作業が
# 要るものは、最後に「setup.sh を 1 回実行する」の形にまとめて案内する。
# 立ち上げのときに要るものを 1 つずつ見つけて、何往復もお願いするのを
# 避けるため (2026-11-14 inori)。
#
# 使い方:
#   tool/linux/doctor.sh
#
# 終了コード: 足りないものが無ければ 0、あれば 1。

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=packages.sh
source "$ROOT/tool/linux/packages.sh"

missing=0
ok() { printf '  ok    %s\n' "$1"; }
ng() { printf '  NG    %s\n' "$1"; missing=1; }
info() { printf '  info  %s\n' "$1"; }

echo "== GitHub"
if gh auth status >/dev/null 2>&1; then ok "gh is logged in"; else ng "gh is not logged in (setup.sh)"; fi
if git config --get credential.https://github.com.helper >/dev/null 2>&1; then
  ok "git uses gh for github.com credentials"
else
  ng "git does not use gh for github.com (setup.sh runs gh auth setup-git)"
fi
if [[ -n "$(git config --get user.name)" && -n "$(git config --get user.email)" ]]; then
  ok "git user.name / user.email are set"
else
  ng "git user.name / user.email are not set (git config --global)"
fi

echo "== sudo / apt"
if sudo -n -l /usr/bin/apt-get >/dev/null 2>&1; then
  ok "apt-get runs without a password"
else
  ng "apt-get needs a password (setup.sh adds /etc/sudoers.d/$SUDOERS_NAME)"
fi
absent=()
for p in "${APT_PACKAGES[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
    absent+=("$p")
  fi
done
if [[ ${#absent[@]} -eq 0 ]]; then ok "apt packages (${#APT_PACKAGES[@]})"; else ng "apt packages missing: ${absent[*]}"; fi
if locale -a 2>/dev/null | grep -qi '^ja_JP\.utf-\?8$'; then ok "ja_JP.UTF-8 locale"; else ng "ja_JP.UTF-8 locale (setup.sh)"; fi

echo "== Flutter"
want=$(grep -m1 'flutter-version:' "$ROOT/.github/workflows/analyze.yml" | awk '{print $2}')
have=$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')
if [[ -n "$have" && "$have" == "$want" ]]; then ok "Flutter $have (CI pin)"; else ng "Flutter ${have:-not found}, CI pin is $want (docs/dev-environment.md)"; fi

echo "== repositories (~/repos)"
for r in "${RELATED_REPOS[@]}"; do
  if [[ -d "$HOME/repos/$r/.git" ]]; then ok "$r"; else ng "$r is not cloned (setup.sh)"; fi
done

echo "== Claude Code"
# autoMode の文面には本番・ステージングの固有名が入るので、settings.local.json
# (gitignore) にしか置けない。setup.sh では入れず、無ければ Claude が書く
# (pooza の一言の承認が要る・docs/dev-environment-claude-code.md「Claude Code の権限設定」)。
if jq -e '.autoMode.allow and .autoMode.soft_deny' "$ROOT/.claude/settings.local.json" >/dev/null 2>&1; then
  ok ".claude/settings.local.json has autoMode"
else
  ng ".claude/settings.local.json has no autoMode (ask Claude to write it; see docs/dev-environment-claude-code.md)"
fi

echo "== secrets"
if [[ -f "${CAPSICUM_SECRETS:-$HOME/.config/capsicum/secrets.env}" ]]; then ok "secrets.env"; else ng "secrets.env is missing (docs/dev-environment.md)"; fi
if [[ -f "$HOME/.sentryclirc" ]]; then ok "$HOME/.sentryclirc"; else ng "$HOME/.sentryclirc is missing"; fi

echo "== desktop session"
info "session type: ${XDG_SESSION_TYPE:-unknown} (over ssh this is the ssh session, not the screen)"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
if gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
     --object-path /org/freedesktop/impl/portal/PermissionStore \
     --method org.freedesktop.impl.portal.PermissionStore.Lookup screenshot screenshot 2>/dev/null \
     | grep -q "'': \['yes'\]"; then
  ok "screenshots via the portal are allowed for host apps"
elif command -v gnome-shell >/dev/null; then
  ng "screenshots via the portal are not allowed (setup.sh)"
else
  info "not GNOME; screenshot permission is not checked"
fi

echo "== Claude can install without sudo (info only)"
if command -v shellcheck >/dev/null; then ok "shellcheck"; else info "shellcheck comes with the apt packages"; fi
if [[ -d "$HOME/repos/capsicum-relay" ]]; then
  rv=$(cat "$HOME/repos/capsicum-relay/.ruby-version" 2>/dev/null)
  if command -v rbenv >/dev/null && rbenv versions --bare 2>/dev/null | grep -qx "$rv"; then
    ok "Ruby $rv (rbenv) for capsicum-relay"
  else
    info "Ruby $rv for capsicum-relay is not installed (rbenv in ~, no sudo needed)"
  fi
fi
max=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null)
info "fs.inotify.max_user_instances = ${max:-?} (dart analyze may need more; docs/dev-environment-desktop.md)"

echo
if [[ "$missing" -eq 0 ]]; then
  echo "Nothing is missing."
else
  echo "Something is missing. Run this once (asks for the sudo password once):"
  echo "  $ROOT/tool/linux/setup.sh"
fi
exit "$missing"
