# capsicum AppImage パッケージング

Phase 2 (#424) でローカル開発機 (Linux 補助機) 用に AppImage を組み立てる
スクリプト一式。配布用の portable AppImage は Phase 4 の GitHub Actions
Ubuntu runner で別途生成する。

## 前提

開発機 (Debian 13 trixie / Ubuntu 24.04 等) に以下が揃っていること。

### システムパッケージ

```sh
sudo apt install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev libsecret-1-dev libwebkit2gtk-4.1-dev \
  libcurl4-openssl-dev default-jdk-headless \
  libfuse2t64 patchelf
```

### linuxdeploy 系ツール

[`docs/dev-environment.md`](../../../docs/dev-environment.md) の補助機セットアップ
方針 (パッケージマネージャ不使用、GitHub Releases から `~/.local/bin/` に直接配置)
に従う。

```sh
mkdir -p ~/.local/bin
cd ~/.local/bin

curl -L -o linuxdeploy \
  https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage

curl -L -o linuxdeploy-plugin-gtk.sh \
  https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh

curl -L -o appimagetool \
  https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage

chmod +x linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool
```

`~/.local/bin` を `PATH` に通しておく (`~/.zshrc` / `~/.bashrc` で
`export PATH="$HOME/.local/bin:$PATH"`)。

### secrets.env (任意)

`~/.config/capsicum/secrets.env` に `SENTRY_DSN` / `RELAY_SECRET` が
設定されていればビルド時に `--dart-define` で注入される。無ければ無効
状態で AppImage が組み上がる (起動・基本動作は問題ないが Sentry に
イベントが飛ばない・push 通知の登録に失敗する)。

## ビルド

```sh
bash packaging/linux/appimage/build.sh
```

成果物: `build/linux/dist/capsicum-<version>-x86_64.AppImage`

## 動作確認

```sh
./build/linux/dist/capsicum-1.24.0-x86_64.AppImage
```

確認項目は #425 (実機検証 Issue) を参照。

## 制約

- 本スクリプトで生成した AppImage は **build した OS の glibc / system
  library 互換性に縛られる**。Debian 13 (glibc 2.41) で組み立てたものは
  Ubuntu 24.04 LTS (glibc 2.39) 以下では動かない。Ubuntu LTS まで広く
  動かせる portable AppImage は Phase 4 の Ubuntu 22.04 runner で生成する。
- video_player は Linux 非対応のため、メディアビューワーで動画を開く
  経路ではエラーになる。詳細は
  [`docs/desktop-plugin-compatibility.md`](../../../docs/desktop-plugin-compatibility.md)
  §2 (`video_player → media_kit 移行`) 参照。
