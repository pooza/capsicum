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

### sha256 pin の更新

CI ([.github/workflows/linux-release.yml](../../../.github/workflows/linux-release.yml))
は [tooling.sha256](tooling.sha256) で linuxdeploy 系バイナリの hash を pin
している (continuous / master の rolling アップデートに対するサプライチェーン
保護)。上流が更新されると CI が落ちるので、明示的に pin を更新する:

```sh
cd ~/.local/bin
sha256sum linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool > \
  /path/to/capsicum/packaging/linux/appimage/tooling.sha256
```

更新前に release notes / commit log を確認して、上流の変更内容を把握すること。

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

build.sh が行う Linux 固有の補正 (#496 対応で導入):

- **plugin .so の RUNPATH 修正**: Flutter ビルドが埋め込むビルドマシン絶対パス (`linux/flutter/ephemeral`) を `$ORIGIN` に書き換え (defensive)
- **`crashpad_handler` の execute bit 補正**: sentry_flutter 同梱の `crashpad_handler` が `-rw-r--r--` で出力されるため `chmod +x`。これが無いと Sentry の native crash dump 経路が EACCES で起動できない
- **`AppRun` を logging wrapper に差し替え**: `~/.local/share/capsicum/logs/capsicum-{timestamp}-{pid}.log` に stderr/stdout を保存 (最新 10 件ローテーション)。デスクトップ起動 (.desktop / Activities) で stderr が捨てられる問題への対処。`stdbuf -oL -eL` でラインバッファ化して native crash 直前まで記録
- **`appimagetool` で seal**: linuxdeploy は AppDir のバンドルだけ行わせ、AppRun 差し替え後に `appimagetool` で AppImage 化

## 動作確認

### ローカルビルドの起動

build.sh が出力する AppImage は実行ビット付き。そのまま起動可能。

```sh
./build/linux/dist/capsicum-1.24.0-x86_64.AppImage
```

### 配布物 (GitHub Releases から DL した AppImage) の検証

リリース直前 / 直後に、Linux 補助機で配布バイナリを実機検証する場合の手順。`linux-release.yml` がタグ駆動で生成して draft Release に添付した AppImage を、pooza が GitHub UI からダウンロード後:

```sh
chmod +x ~/Downloads/capsicum-1.24.0-x86_64.AppImage
~/Downloads/capsicum-1.24.0-x86_64.AppImage
```

公開済み Release のアセットは curl からも取得可能 (draft 中は pooza のみアクセス可):

```sh
curl -LO https://github.com/pooza/capsicum/releases/download/v1.24.0/capsicum-1.24.0-x86_64.AppImage
chmod +x capsicum-1.24.0-x86_64.AppImage
./capsicum-1.24.0-x86_64.AppImage
```

確認項目は [#425](https://github.com/pooza/capsicum/issues/425) (Linux 実機検証 Issue) を参照。

## 制約

- 本スクリプトで生成した AppImage は **build した OS の glibc / system
  library 互換性に縛られる**。Debian 13 (glibc 2.41) で組み立てたものは
  Ubuntu 24.04 LTS (glibc 2.39) 以下では動かない。Ubuntu LTS まで広く
  動かせる portable AppImage は Phase 4 の Ubuntu 22.04 runner で生成する。
- video_player は Linux 非対応のため、メディアビューワーで動画を開く
  経路ではエラーになる。詳細は
  [`docs/desktop-plugin-compatibility.md`](../../../docs/desktop-plugin-compatibility.md)
  §2 (`video_player → media_kit 移行`) 参照。
