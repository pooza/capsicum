### 4.5 Linux 配布（v1.24〜）

Linux は fastlane を使わず GitHub Actions の Ubuntu runner ジョブ ([.github/workflows/linux-release.yml](../../../.github/workflows/linux-release.yml)) でビルドする。配布形態は AppImage 単独（Flathub は [#604](https://github.com/pooza/capsicum/issues/604) で 2026-05-29 に断念、経緯は CLAUDE.md デスクトップ対応節を参照）。

#### AppImage

タグ駆動 (`v*.*.*`) で `linux-release.yml` の `appimage` ジョブが起動し:

1. ubuntu-22.04 で `flutter build linux --release` (glibc 2.35 互換性確保)
2. `linuxdeploy` + `linuxdeploy-plugin-gtk` で AppDir を組み立て、`appimagetool` で AppImage 化
3. `capsicum-<version>-x86_64.AppImage` を **draft Release** に添付
4. pooza が GitHub UI で draft Release をレビューしてから手動で publish

draft で生成するのは「リリース作業の委託範囲」(自動公開はしない) ルールに従う。

> ⚠️ **タグより先に draft Release を作ると、CI がそれを publish してしまう**（v1.38 で実害）。リリースノートを先に置こうとして `gh release create --draft` 等で Release を先出しすると、CI の `softprops/action-gh-release@v2` は `draft: true` を指定していても「既存 Release を更新する」経路に入り、**draft フラグを落として公開してしまう**。`draft: true` はこの action が Release を**新規作成するときにしか効かない**。[linux-release.yml](../../../.github/workflows/linux-release.yml) / [windows-release.yml](../../../.github/workflows/windows-release.yml) の両方が該当。
>
> 回避: **Release を先に作らず CI に作らせ、生成された draft へ後からリリースノートを書く**。どうしても先出しした場合は、CI 完走後に draft へ戻し直したかを必ず確認する。自動公開しない委託範囲ルールが、事故で破れる経路はここ。

#### ナイトリー（報告者に検証してもらう AppImage を、リリースを待たずに出す）

`linux-release.yml` には **`workflow_dispatch` が最初からある**。develop で回すと `capsicum-appimage` という **workflow artifact**（約 156MB・retention 14 日）が出る。

```sh
gh workflow run linux-release.yml --repo pooza/capsicum --ref develop
```

⚠ **Release への添付は `if: startsWith(github.ref, 'refs/tags/')` で tag 限定**なので、develop で回しても**公開物は一切生まれない**。⚠ **artifact のダウンロードには GitHub ログインが要る**。⚠ **ビルド番号を先に上げてから回す** — 報告者が「どちらを試したか」を版で言えなくなる。

⚠ **「手元に Linux のビルド環境が無いから検証が回せない」は誤り**（[#1085](https://github.com/pooza/capsicum/issues/1085) / [#1104](https://github.com/pooza/capsicum/issues/1104) の確認がこれで 2 日止まった）。

#### ローカル動作確認

```sh
bash distribution/linux/appimage/build.sh
```

ビルド + 起動の詳細・配布物（GitHub Releases から DL した AppImage）の検証手順は [distribution/linux/appimage/README.md](../../../distribution/linux/appimage/README.md) §動作確認を参照。

#### GitHub Release のリリースノート（Linux セクションテンプレート）

Linux は**ストア展開が無く、この AppImage インストールコマンドが最優先の導線**になるため、リリースノートには**必ず**この Linux セクションを入れる（v1.38 でこのセクションごと抜けた経緯あり）。手順本体は [distribution/linux/INSTALL.md](../../../distribution/linux/INSTALL.md) を single source of truth とし、ワンライナーは**サイト配信の install.sh**（バージョン非依存・常に最新 Release を取得）を案内する。

````markdown
## Linux (AppImage)

下記ワンライナーで最新版のダウンロード〜メニュー登録まで完了します（`sudo` 不要・`$HOME` 配下のみ）:

```sh
curl -fsSL https://capsicum.shrieker.net/install.sh | bash
```

`curl` が無ければ `wget -qO- https://capsicum.shrieker.net/install.sh | bash`。手動配置・FUSE2 fallback・アンインストールは [インストール手順](https://capsicum.shrieker.net/desktop/) を参照してください。
````

> **install.sh / uninstall.sh の site 同期チェック（毎リリース）**: `distribution/linux/install.sh` または `uninstall.sh` を変更したリリースでは、capsicum-site (`~/repos/capsicum-site`) の同名ファイルへ機能を反映して push する（`capsicum.shrieker.net/install.sh` は正本のミラー。URL を `raw.githubusercontent`→`capsicum.shrieker.net` に差し替えた本番変種なので byte 一致ではなく #707 等の機能変更を移植する形）。ワンライナーはバージョン非依存なので、スクリプト未変更のリリースでは同期不要。同期済みかは `curl -fsSL https://capsicum.shrieker.net/install.sh | grep -c '<変更の目印>'` で確認できる。

