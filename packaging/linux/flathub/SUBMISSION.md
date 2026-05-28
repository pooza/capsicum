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
       strip-components: 0   # ← 必須。落とし穴①を参照
       dest: bundle
     - type: file
       url: https://raw.githubusercontent.com/pooza/capsicum/<commit SHA>/packaging/linux/shared/net.shrieker.capsicum.desktop
       sha256: <desktop の sha256>
     # metainfo / icons も同様に raw URL に変更 (URL の ref は落とし穴②を参照)
   ```

2. icon ファイルも各サイズの `type: file` を、macOS asset の raw URL から
   取得する形に書き換え

   ```yaml
   - type: file
     url: https://raw.githubusercontent.com/pooza/capsicum/v1.24.0/packages/capsicum/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png
     sha256: <sha256>
     dest-filename: icon-256.png
   ```

### 落とし穴 (2026-05-29 v1.29.0 提出準備で判明)

提出 manifest を派生する際、必ず踏む2点。

#### ① flat tarball には `strip-components: 0` を明示する

`capsicum-bundle-<ver>-x86_64.tar.gz` は `tar -C bundle .` で作られており、
中身 (`./capsicum` / `./lib/` / `./data/`) がラッパーディレクトリなしで
ルート直下に入っている。flatpak-builder の `type: archive` は
**`strip-components` がデフォルト 1** なので、未指定だと最上位
(`capsicum` 実行ファイル・`lib/`・`data/`) が剥がされて `bundle/` が空に
なり、`cp -r bundle/. /app/bin/` が無意味になる。`strip-components: 0` を
明示して回避する。

#### ② metadata/icon の raw URL は「リリースタグ」でなく「commit SHA」にピンする

`<release version="x.y.z">` を metainfo に追記するのは通常タグを切った後
なので、`raw.githubusercontent.com/pooza/capsicum/vX.Y.Z/...metainfo.xml`
(タグ参照) だと **その版の `<release>` entry を含まない古い metainfo を
引いてしまう** (Flathub レビューは `<release>` の最新版と pubspec の一致を
見るため不可)。手順:

1. metainfo に当該リリースの `<release>` を追記して develop に commit + push
2. その commit SHA を `raw.githubusercontent.com/pooza/capsicum/<SHA>/...`
   の ref に使う (タグでなく SHA)。sha256 pin する以上、可変なタグより
   不変な SHA の方が自然
3. bundle tarball は Release 資産なのでタグ由来の URL のままでよい
   (metadata だけ SHA 参照になる = ref が混在するが問題ない)

v1.29.0 提出時は commit `f2ffc7c` (metainfo に 1.28.1 / 1.29.0 追記) を
ピン先に使用した。

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
- **base ブランチ: `new-pr` (必須)** — `master` を base にすると Flathub
  の auto-close ボットに即座に弾かれる。2026-05-10 の初回提出時に
  flathub/flathub#8625 でこれを踏み、base を `new-pr` に直して #8626 として
  再提出した経緯あり。`gh pr create --base new-pr ...` で指定すること。
  fork 元の作業ブランチも `git checkout -b xxx upstream/new-pr` で
  upstream/new-pr から派生させる必要がある (master から派生すると
  「pooza:branch has no history in common with flathub:new-pr」エラーで
  PR を作れない)。
- マニフェストファイル: ルートに `net.shrieker.capsicum.yml` を配置

申請から採択までは 1〜4 週間程度を見込む。レビューで指摘される代表的な
ポイント:

- `finish-args` の `--filesystem=` を最小化 (xdg-portal で代替できないか)
- AppStream metainfo の `<screenshots>` セクション (Phase 5b で
  packaging/linux/screenshots/ 以下に PNG を置き、metainfo の
  `<image>` から SHA 参照の raw URL で引く形に整理済み。次回以降の
  リリースでは screenshot 更新時に metainfo の SHA を併せて差し替える)
- `<release>` セクションの date と version が pubspec と一致しているか
- アイコンが SVG または最低 256x256 PNG か (本 manifest は OK)

## デモ録画: 初回起動状態へのリセット

Flathub PR テンプレートは **Linux Flatpak 上で動作するデモ動画 (必須)** を
要求する。新規ユーザー視点 (EULA 表示 → プリセットサーバー選択 → OAuth →
ホーム TL) を録るには、アプリを「真の初回起動状態」に戻す必要がある。

### なぜログアウトだけでは不十分か

初回フローのゲートは `splash_screen.dart`:

```text
eula_accepted == false  → /eula 表示 → 承諾後 nextRoute へ
nextRoute = hasAccount ? '/home' : '/server'   // アカウント無し → /server
```

保存先が非対称なので、片方だけ消しても初回状態にならない:

- **EULA 同意フラグ** (`eula_accepted`, bool): `shared_preferences`
  = アプリデータ側 (`~/.var/app/net.shrieker.capsicum/`)
- **アカウント** (`secret_<key>` / `client_creds_<host>`):
  `flutter_secure_storage` → Linux は libsecret = **ホストのキーリング側**
  (manifest の `--talk-name=org.freedesktop.secrets`)。`rm -rf ~/.var/app`
  しても残る

ログアウトだけ → EULA が戻らない。アプリデータ消去だけ → アカウントが
キーリングに残り EULA 通過後に `/home` へ飛んでログイン導線が録れない。
**両方** 必要。

### リセット手順

```sh
# 1. capsicum を起動し、アプリ内で全アカウントをログアウト
#    (v1.29.0 以降は #621 修正済みで keyring の secret_* が綺麗に消える)
# 2. アプリを終了
# 3. アプリデータを消去 (eula_accepted / キャッシュ / ウィンドウ位置をリセット)
rm -rf ~/.var/app/net.shrieker.capsicum
# 4. 再起動 → EULA → 承諾 → /server (プリセット一覧) が出れば成功。ここから録画
```

手順3はアプリ本体を消さない (`~/.var/app` はユーザーデータのみ。インス
トール済み Flatpak は別の場所)。

### フォールバック

手順4で EULA 後に `/home` へ飛んだら、キーリングにアカウントが残存して
いる。seahorse (パスワードと鍵) を開き `capsicum` / `net.shrieker.capsicum`
ラベルのエントリを削除して再起動。手順1のログアウトが効いていれば不要。

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
