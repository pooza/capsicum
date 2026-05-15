# Linux インストール手順 (AppImage 直配)

> 配布対象は **x86_64 アーキの主要なデスクトップ Linux ディストロ**です。AppImage 形式での単独実行ファイル配布のため、システムへの導入は不要・削除はファイル削除のみで完結します。Flathub 公開は申請中で、採択後は `flatpak install flathub net.shrieker.capsicum` でも導入できるようになります。

## インストール手順

1. 本 Release のアセットから `capsicum-<version>-x86_64.AppImage` をダウンロード

2. 実行権限を付与:

   ```sh
   chmod +x capsicum-1.25.0-x86_64.AppImage
   ```

3. 任意の場所に配置 (例: `~/Applications/` や `~/bin/`):

   ```sh
   mkdir -p ~/Applications
   mv capsicum-1.25.0-x86_64.AppImage ~/Applications/
   ```

4. ダブルクリック または ターミナルから起動:

   ```sh
   ~/Applications/capsicum-1.25.0-x86_64.AppImage
   ```

5. (任意) デスクトップ統合 (アプリ一覧への登録): [AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher) を導入しておくと、初回起動時にアプリ一覧への追加とアイコン登録を自動でやってくれます

## FUSE2 が無い環境向けの fallback

AppImage は **libfuse2** に依存します (`libfuse2` / `libfuse2t64` 等のパッケージ名はディストロ依存)。FUSE2 が無い環境 (FUSE3 のみのディストロ、コンテナ等) で `dlopen(): libfuse.so.2: cannot open shared object file` のようなエラーが出る場合は、抽出モードで起動できます:

```sh
./capsicum-1.25.0-x86_64.AppImage --appimage-extract-and-run
```

または `libfuse2` 系のパッケージを導入してください (Debian/Ubuntu: `sudo apt install libfuse2t64`、Fedora: `sudo dnf install fuse-libs`)。

## 動作要件

- **アーキ**: x86_64 (ARM64 / aarch64 ビルドは未提供)
- **ディストロ**: Debian 13 / Ubuntu 22.04 以降の主要ディストロを想定
- **glibc**: 2.35 以上 (Ubuntu 22.04 / Debian 12 相当が下限)
- **GTK**: GTK 3.24 以降 (主要デスクトップ環境では標準で導入済み)
- **FUSE**: libfuse2 (上記 fallback 経路あり)

## 日本語 IME (Input Method)

主要な GTK IM module を AppImage に同梱しています:

| IM | 同梱 | 検証 |
|---|---|---|
| ibus | ✓ | **動作確認済み** (Debian 13 + ibus-mozc + LXQt / X11) |
| fcitx5 | ✓ | **動作報告あり** (外部ユーザーによる確認、開発者環境では未検証) |
| uim | ✓ | best-effort (開発者環境で未検証、動作報告歓迎) |

ホスト側に該当 IM フレームワークがインストールされていれば、capsicum 起動時に環境変数 `GTK_IM_MODULE` で自動的に拾われます。動作しない場合は明示指定で試してください:

```sh
GTK_IM_MODULE=ibus ./capsicum-1.25.0-x86_64.AppImage
```

ibus-mozc 以外の組み合わせは未検証のため、問題があれば [Issue](https://github.com/pooza/capsicum/issues) にご報告ください。

## ログ場所

起動時の標準出力 / 標準エラーは以下に保存されます (AppImage の `AppRun` で logging wrapper を介してリダイレクト):

```
~/.local/share/capsicum/logs/
```

不具合報告時はこのディレクトリのログを添付してください。

## アンインストール

AppImage ファイル本体を削除するだけです:

```sh
rm ~/Applications/capsicum-1.25.0-x86_64.AppImage
```

`flutter_secure_storage` がホスト鍵管理 (libsecret / GNOME Keyring 等) を介して保存しているデータも削除する場合は、Seahorse 等のキーチェーン管理ツールで `capsicum` 関連エントリを手動削除してください (アカウント情報 / OAuth トークン)。

ログとアプリ設定:

```sh
rm -rf ~/.local/share/capsicum
rm -rf ~/.config/capsicum
```

## Flathub について

Flathub への申請手続き中です。採択後は以下のコマンドで導入可能になります:

```sh
flatpak install flathub net.shrieker.capsicum
flatpak run net.shrieker.capsicum
```

Flatpak 版は Flathub 提供 runtime (`org.gnome.Platform//49`) で動作し、サンドボックス内で完結します。
