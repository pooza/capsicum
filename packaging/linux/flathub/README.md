# capsicum Flatpak / Flathub パッケージング

Phase 3 (#424) でローカル開発機に Flatpak を組み立てて起動確認する
ための manifest 一式。Flathub 公式リポジトリへの submission 用 manifest
は Phase 5a でオフラインビルド対応版に書き換えた上で別途用意する。

## 前提

### システムパッケージ

```sh
sudo apt install -y flatpak flatpak-builder
```

### Flathub remote

```sh
flatpak remote-add --user --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo
```

### Runtime / SDK

```sh
flatpak install --user flathub \
  org.gnome.Platform//49 \
  org.gnome.Sdk//49
```

合計 ~1.4GB のダウンロードが発生する。

`org.gnome.Platform` を採用する理由は、`flutter_web_auth_2` が引く
`desktop_webview_window` プラグインが `libwebkit2gtk-4.1.so.0` をリンク
しており、`org.freedesktop.Platform` には webkit2gtk が含まれないため。
GNOME Platform は GNOME 標準で webkit を同梱しているのでそのまま動く。

## ビルド

```sh
bash packaging/linux/flathub/build.sh
```

完了後:

```sh
flatpak run --user net.shrieker.capsicum
```

## アンインストール

```sh
flatpak uninstall --user net.shrieker.capsicum
```

## Flathub への提出 (Phase 5a で対応)

本 manifest はネットワーク有り (`flatpak-builder` が host から bundle
ディレクトリ等を `type: dir` で取り込む) を前提にしているため、Flathub
の sandboxed CI ではそのまま通らない。Phase 5a で:

- `sources` を Flathub からアクセス可能な archive (GitHub Releases に
  bundle tarball を上げる等) に置き換え
- `pub get` 相当の依存解決を事前にホストで済ませて bundle に固める
- `flatpak-builder-lint` を通過させる

の対応を行う。
