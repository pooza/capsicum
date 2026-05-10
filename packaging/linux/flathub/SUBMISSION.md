# Flathub 提出手順

`packaging/linux/flathub/net.shrieker.capsicum.yml`（ローカル動作確認用）から、
Flathub の公式リポジトリに提出するための manifest を派生させる手順。

## Flathub サンドボックスの制約

Flathub の CI ビルドサンドボックスは **ネットワーク無効**。`flutter pub get` を
manifest 内で走らせることはできないため、Flutter で予め作った release bundle を
そのまま `type: archive` で取り込む方式を採る。

## 全体フロー

```
1. capsicum 側でリリースタグ (v1.24.0) を切る
2. linux-release.yml の appimage ジョブが
   - capsicum-1.24.0-x86_64.AppImage
   - capsicum-bundle-1.24.0-x86_64.tar.gz   ← Flathub 用 source
   を draft Release に添付
3. pooza が draft Release を publish (実バイナリのレビュー後)
4. flathub/net.shrieker.capsicum リポジトリ (Flathub 採択時に
   Flathub 側で作成される) に提出 manifest を push する PR を出す
   - manifest の sources は GitHub Releases の tarball URL を指す
   - sha256 は手元で計算した値を埋め込む
5. Flathub レビュー期間 (1〜4 週) → 採択
```

## 提出 manifest の派生

`packaging/linux/flathub/net.shrieker.capsicum.yml` を Flathub 提出用にコピーして
以下の差分を加える。

### 変更点

1. `modules.capsicum.sources` の `type: dir` (path: build/linux/...) を
   `type: archive` (url: GitHub Releases の tarball URL) に置換

   置換後の例:
   ```yaml
   sources:
     - type: archive
       url: https://github.com/pooza/capsicum/releases/download/v1.24.0/capsicum-bundle-1.24.0-x86_64.tar.gz
       sha256: <tarball の sha256>
       dest: bundle
     - type: file
       url: https://raw.githubusercontent.com/pooza/capsicum/v1.24.0/packaging/linux/shared/net.shrieker.capsicum.desktop
       sha256: <desktop の sha256>
     # metainfo / icons も同様に raw URL に変更
   ```

2. icon ファイルも各サイズの `type: file` を、macOS asset の raw URL から
   取得する形に書き換え

   ```yaml
   - type: file
     url: https://raw.githubusercontent.com/pooza/capsicum/v1.24.0/packages/capsicum/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png
     sha256: <sha256>
     dest-filename: icon-256.png
   ```

### sha256 の計算方法

linux-release.yml の `appimage` ジョブで生成された tarball を Releases から
ダウンロードして:

```sh
sha256sum capsicum-bundle-1.24.0-x86_64.tar.gz
```

または GitHub Actions のログ末尾にも sha256 が出力されている (`Pack Flutter
bundle as tarball` step)。

## Flathub アプリ ID 申請

Flathub への新規 submission は flathub/flathub リポジトリに以下のような
PR を出す形:

- リポジトリ: <https://github.com/flathub/flathub>
- 申請ブランチ: `new-pr` 系
- マニフェストファイル: ルートに `net.shrieker.capsicum.yml` を配置

申請から採択までは 1〜4 週間程度を見込む。レビューで指摘される代表的な
ポイント:

- `finish-args` の `--filesystem=` を最小化 (xdg-portal で代替できないか)
- AppStream metainfo の `<screenshots>` セクションが必要 (本 manifest には
  まだ無いので、Phase 5b で追加)
- `<release>` セクションの date と version が pubspec と一致しているか
- アイコンが SVG または最低 256x256 PNG か (本 manifest は OK)

## 採択後の運用

採択されると `flathub/net.shrieker.capsicum` リポジトリが Flathub 側で
作成され、capsicum 側のリリースに合わせて manifest 更新 PR を継続的に
出す形になる。`flatpak-external-data-checker` bot を導入すれば自動化
できる (本 Issue では対応せず別 Issue 化候補)。

## ローカル動作確認用 manifest との関係

`packaging/linux/flathub/net.shrieker.capsicum.yml` は **開発機での
動作確認専用**。本 SUBMISSION.md の手順で派生させた manifest を
flathub/net.shrieker.capsicum リポジトリに置く。capsicum リポジトリ
内に提出 manifest を完成形で置かないのは、Flathub 側で manifest を
maintain するのが Flathub の流儀だから。
