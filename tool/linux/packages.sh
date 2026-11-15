# shellcheck shell=bash
# Linux の開発・検証機に要るものの一覧。doctor.sh と setup.sh が読む (正本はここ)。
# 各パッケージが何のために要るかは docs/dev-environment-desktop.md「Linux 固有」。

# shellcheck disable=SC2034
APT_PACKAGES=(
  clang cmake ninja-build pkg-config
  libgtk-3-dev libsecret-1-dev libwebkit2gtk-4.1-dev
  libcurl4-openssl-dev default-jdk-headless
  libmpv-dev libasound2-dev libayatana-appindicator3-dev
  libfuse2t64 patchelf
  gh jq shellcheck
  language-pack-ja ibus-mozc
  build-essential libssl-dev libyaml-dev zlib1g-dev libffi-dev libreadline-dev
)

# ~/repos に置く関連リポジトリ (capsicum 本体を除く)。
# Mastodon / Misskey のフォークは大きいので置かない (版は raw.githubusercontent で読む)。
# shellcheck disable=SC2034
RELATED_REPOS=(
  capsicum-relay
  capsicum-site
  mulukhiya-toot-proxy
  chubo2
)

# apt-get をパスワードなしで回すための sudoers のファイル名。
# shellcheck disable=SC2034
SUDOERS_NAME=capsicum-apt
