### 4.1 バージョン更新・依存関係の更新

```bash
# pubspec.yaml の version を更新（例: 1.0.0+1 → 1.0.1+2）
# 注意: ビルド番号（+N）は一度ストアにアップロードすると、リリースを破棄しても再利用不可。
# 上げ直す場合は必ずビルド番号をインクリメントすること。

# Windows の MSIX パッケージバージョンは手動更新不要（#798）。windows-release.yml が
# pubspec の version(+build) から <major>.<minor>.<build>.0 を導出し --version で
# msix:build / msix:pack に渡す（pubspec の msix_config.msix_version は未指定）。
# 第4オクテット（Revision）は Store 予約で 0 固定、ビルド番号を第3オクテットに載せて
# full name を一意化する。この自動化以前は msix_version を手動で上げる運用で、上げ忘れると
# 1.43.0.0 のまま固定され、開発中の Store フライトが同じ full name を消費していると
# 製品版提出が「フル ネーム 9AFBB08E.capsicum_X.Y.Z.0_X64 が重複」で弾かれた（v1.43.0 で実踏）。

# 依存パッケージを最新互換バージョンに更新（リリースのタイミングで実施）
#
# ⚠ このコミットのメッセージは必ず `chore(deps):` で始めるか、本文に [pubspec-lock]
# を入れること。#970 の lock ガード（analyze.yml）は「pubspec.yaml / workflow の pin を
# 伴わない pubspec.lock 単独の変更」を落とすので、`chore:` だと CI が赤くなる。
# v1.56 のリリース作業で実際に踏み、amend + force-push で直した。
cd packages/capsicum
flutter pub upgrade

# メジャーバージョンアップも含める場合（pubspec.yaml の制約も更新される）
flutter pub upgrade --major-versions
```

### 4.2 ビルド + アップロード

> ⚠️ **環境変数は必ず `export` で親シェルに設定すること**。
> `VAR="..." flutter build ... --dart-define=KEY=$VAR` のように単一
> コマンドラインで前置すると、`$VAR` の展開はコマンドライン構築時に
> **親シェルから** 行われるため、前置した `VAR` は flutter にしか
> 環境変数として渡らず、`$VAR` は **空文字列** に展開されてしまう。
> その結果 `--dart-define=KEY=` として空値がビルドに焼き込まれ、
> Sentry / RELAY シークレットが効かない。`v1.21.0+50` ではこのミスで
> 全アカウント push 不達 (relay register 401) が発生し、`+51` で
> 再ビルド対応した。`export` 文と `flutter build` 文は **必ず別文**
> （独立した行）で書き、`\` で繋いで 1 行に圧縮しないこと。

#### ⚠ ビルド前に古い DerivedData を落とす（v1.63 で 22 分かかった）

**`~/Library/Developer/Xcode/DerivedData` は内蔵ディスクに固定で置かれ、リポジトリの場所と無関係に育つ。**⚠⚠ **Xcode は作業ディレクトリのパスごとに別エントリを作り、古いものを自動で消さない。**v1.63 のリリース時、6〜8 月分を含む `Runner-*` が 13 個・計 14G 残っており、内蔵の空きが 8.7GB まで落ちていた。その結果 `flutter clean` の `xcodebuild clean` が **502 秒**（通常の 5 倍）かかり、1 回のビルドが 22 分になった。

⚠ **2026-09-04 に DerivedData / Archives / CompilationCache を外部ボリュームへ移した**（Xcode → Settings → Locations）。置き場所は `defaults read com.apple.dt.Xcode | grep IDECustom` で確認できる。

```sh
ls -1 "$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation)" | grep -c '^Runner-'
rm -rf "$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation)"/*
```

⚠ **見るのはサイズではなくエントリ数。**`clean` の所要時間は `Runner-*` の数に効く。外部は容量が潤沢なので、**逼迫による激遅化はもう起きない**。

⚠ **毎リリース掃除する必要は無い。**目安は「`clean` が体感で長くなったら」。3 か月で 13 個・14G が溜まって 502 秒になった実績があるので、**数か月に一度**で足りる。

⚠ **ビルド生成物だけなので消して安全**（次回の初回ビルドだけ長くなる）。⚠ **Xcode が動いていると `Index.noindex` が残るが実害はない。**

## ⚠⚠ 「外部ボリュームだから遅い」は誤り（実測で否定済み）

小ファイル 5000 件の作成・削除を両方で実測したところ、**内蔵 6.29s / 外部(USB SSD) 6.49s、削除は外部のほうが速い**（2026-09-04）。さらに**移設後のフルビルドは 22 分 → 10 分 34 秒**、`Cleaning Xcode workspace` は **502.8s → 137.9s**、`Xcode archive` も **245s → 189s** と全項目で改善した。

**遅さの原因は容量逼迫であって配置ではない。**⚠ **推測で配置を疑わないこと。**

```bash
cd packages/capsicum

# クリーンビルド（シミュレータバイナリ混入防止のため必須）
flutter clean
flutter pub get
cd ios
pod install --repo-update
cd ..

# シークレット環境変数を読み込む（1.7 で作成した secrets.env を source）
source ~/.config/capsicum/secrets.env

# 値が空でないか確認（空展開事故の予防、+50 で踏んだ罠を再発させない）
echo "SENTRY_DSN length=${#SENTRY_DSN} RELAY_SECRET length=${#RELAY_SECRET}"
# 両方とも 0 でないこと。0 だと secrets.env が壊れているか source 失敗

# iOS: ビルド → TestFlight アップロード
flutter build ipa --release \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=SENTRY_ENV=production \
  --dart-define=RELAY_SECRET=$RELAY_SECRET
cd ios
fastlane beta
cd ..

# Android: ビルド → Play Store 内部テストトラックにアップロード
flutter build appbundle --release \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=SENTRY_ENV=production \
  --dart-define=RELAY_SECRET=$RELAY_SECRET
cd android
fastlane internal
cd ..

# macOS: flutter build → xcodebuild archive → exportArchive で .pkg 生成 → TestFlight アップロード
# `flutter build macos` 単体では Apple Development 署名 + Mac App Development profile が
# 埋め込まれるだけで App Store 提出には使えない。Generated.xcconfig に DART_DEFINES を反映
# させたうえで xcodebuild archive 経由で Apple Distribution + Mac App Store profile に切り替える。
flutter build macos --release \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=SENTRY_ENV=production \
  --dart-define=RELAY_SECRET=$RELAY_SECRET
xcodebuild -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -archivePath build/macos/capsicum.xcarchive \
  -allowProvisioningUpdates \
  archive
xcodebuild -exportArchive \
  -archivePath build/macos/capsicum.xcarchive \
  -exportOptionsPlist macos/ExportOptions.plist \
  -exportPath build/macos \
  -allowProvisioningUpdates
# build/macos/capsicum.pkg が生成される
cd macos
fastlane beta
cd ..
```

> ⚠️ **`fastlane beta` は「アップロード完了」と「処理待ちの終了」を分けて扱うこと。**
> `Successfully uploaded the new binary to App Store Connect` が出た時点でバイナリは
> ASC に渡っており、以降の `Waiting for the build to show up in the build list` は
> 30 秒間隔のポーリングにすぎない。**同じ行が並ぶだけなので外からは停止と区別がつかず、
> 誤って止められやすい**（2026-08-07 の macOS build 166 で、背景実行の timeout を 10 分に
> 設定していたためポーリング中に打ち切られ、続けて手動でも停止された。どちらの時点でも
> アップロードは完了済みだった）。自動化で回すときは **(a) timeout を処理待ち 5-10 分に
> 張り付いた値にしない、(b) アップロード成功行が出たら報告していったん離れ、状態確認は
> §4.4 の ASC API に切り替える**（`upload_to_testflight` に
> `skip_waiting_for_build_processing` を渡す手もある）。

> ⚠️ **`flutter build ipa` は `packages/capsicum/ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved` を解決し直す。** SwiftPM の transitive 依存（GoogleDataTransport / GoogleUtilities 等）がパッチ更新されると、ビルドの副作用として lock が書き換わる。
>
> **コミットするのは pin が動いたときだけ**（`"version" : "10.1.0"` のような依存の版）。出荷したバイナリと一致させるのが目的なので、pin が動いていれば取り込む（v1.61 で GoogleDataTransport 10.1.0→10.1.1 / GoogleUtilities 8.1.2→8.1.3 を取り込んだのがこれ）。
>
> ⚠⚠ **形式だけの差分（トップレベルの `"version" : 2` ⇄ `3` と `originHash` の増減）は取り込まない。**`git checkout -- <path>` で捨てる。**この形式は Xcode の版が決めており、`flutter-version` は 3.44.6 に pin してあるが Xcode は pin していない**ので、端末を替えるたびに 2 ⇄ 3 を往復する。取り込むと「誰も触っていない差分」を毎リリース作り続けることになり、**手順書が避けようとしている状態を手順書どおりにやると作ってしまう**（v1.61 で 2→3 を取り込み、v1.62 では別の Mac が pin を 1 つも動かさずに 3→2 へ戻した。#1067）。
>
> **端末間で Xcode を揃える運用は取らない。**揃えるコストに対して、形式差が出荷バイナリに与える影響がゼロ（pin が同一なら解決結果も同一）だから。`.gitattributes` でも吸えない — 形式差は空白でもマージでもなく**ファイルの正当な中身**で、`git` 側に「無視するが追跡は続ける」表現が無い（`skip-worktree` は端末ローカルの旗で、コミットして共有できない）。**ビルド後に人が捨てる**のが唯一の受け口なので、ここに書いてある。
>
> ⚠ **紛らわしい同名ファイルが 4 つある。**`ios` / `macos` × `Runner.xcworkspace/…` / `Runner.xcodeproj/project.xcworkspace/…` の 4 本が追跡されているが、**ビルドが書き戻すのは workspace 側だけ**（`flutter build` は `Runner.xcworkspace` を開く）。`Runner.xcodeproj/project.xcworkspace` 配下の 3 本は CocoaPods → SwiftPM 移行（#836）以降 1 度も更新されておらず、iOS のものは pin が古いまま止まっている。**参照されないので実害は無いが、差分を見るときにこちらを見ない。**

> **macOS の `.pkg` 生成が iOS と異なる理由:**
> iOS は `flutter build ipa --release` 一発で App Store 提出可能な ipa が出来るが、macOS の `flutter build macos --release` は Apple Development 証明書 + Mac App Development profile を埋め込んだ `.app` を出力するだけで、Mac App Store には提出できない。`xcodebuild archive` + `-exportArchive` を経由することで Apple Distribution + Mac App Store profile + 3rd Party Mac Developer Installer による `.pkg` 署名が automatic に行われる。`flutter build macos` を先に走らせるのは Generated.xcconfig の `DART_DEFINES` を更新するため（archive 単独では `--dart-define` を渡せない）。

> ⚠️ **各プラットフォームは「ビルド → beta アップロード（§4.2）→ 審査提出（§4.3）」まで一気通貫でやり切ってから次の OS に移ること。** `flutter clean` は `build/` 全体を消すため、iOS をビルド→beta 後に Android / macOS をビルドすると、その `flutter clean` で `build/ios/ipa/capsicum.ipa` が消え、§4.3 の iOS `fastlane release`（`ipa:` パスを検証する）が `Could not find ipa file` で落ちる（v1.43.0 で実際に踏んだ）。加えて **iOS/macOS のアーカイブはビルド毎にビルド番号を自動 +1 する**ため、消えた ipa を後から再ビルドすると番号がズレ（147→148）、`skip_binary_upload:true` の deliver が「未アップロードの 148」を待ち続けてハングする。復旧するなら、`ipa:` を外して `app_identifier:` + `build_number:'<既に VALID なビルド番号>'` を渡した `upload_to_app_store`（`skip_binary_upload:true`）で既存ビルドを名指し提出する。

#### Android: 16KB ページサイズ対応（必須・irondash をローカルビルド）

Google Play は **64bit ネイティブ `.so` の LOAD セグメントが 16KB 整列**（`p_align >= 16384`）でないと製品版昇格を `Artifact does not support 16KB page size` で拒否する（2026-06 にハード強制が有効化。それ以前は警告だったため v1.41.1 までは 4KB のまま production に出ていた）。

問題のライブラリは `irondash_engine_context`（`super_drag_and_drop` → `super_native_extensions` の transitive 依存）。cargokit はデフォルトで **GitHub の precompiled `.so` をダウンロード**して使うが、irondash 0.5.5（最新）の precompiled は 4KB 整列で upstream に修正版がない（姉妹の super_native_extensions は precompiled が 16KB 済み）。precompiled は再整列できないため、**ローカル Rust ビルドに切り替えて 16KB リンカフラグを注入**する。

恒久設定（コミット済み）: [`packages/capsicum/android/cargokit_options.yaml`](../../../packages/capsicum/android/cargokit_options.yaml) に `use_precompiled_binaries: false`。これで cargokit は irondash / super_native_extensions をローカルビルドする。

**Android ビルドマシンの前提**: rustup + android ターゲットが必要（cargokit は rustup 不在だと precompiled に戻る）。

```bash
# 一度だけ（rustup 未導入のマシン）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
```

`flutter build appbundle` を走らせる際、§4.2 の手順に加えて **リンカフラグを export し、stale な gradle daemon を止める**（daemon が古い環境を握っていると cargokit にフラグが渡らず 4KB のままになる。一度これで踏んだ）:

```bash
export PATH="$HOME/.cargo/bin:$PATH"          # rustup を PATH に
export CARGO_ENCODED_RUSTFLAGS='-Clink-arg=-Wl,-z,max-page-size=16384'
( cd android && ./gradlew --stop )            # 古い daemon を破棄（新 daemon に env を継承させる）
flutter clean && flutter pub get
# …§4.2 の flutter build appbundle …
```

**アップロード前に必ず整列を検証する**（フラグが silent に効かないことがあるため必須ゲート）:

```bash
cd packages/capsicum
unzip -o build/app/outputs/bundle/release/app-release.aab 'base/lib/arm64-v8a/*.so' -d /tmp/so >/dev/null
# 各 .so の PT_LOAD p_align が 16384 以上であること（特に libirondash_engine_context_native.so）
for f in /tmp/so/base/lib/arm64-v8a/*.so; do
  printf '%s ' "$(basename "$f")"
  python3 - "$f" <<'PY'
import sys,struct
d=open(sys.argv[1],'rb').read(); off=struct.unpack_from('<Q',d,0x20)[0]
es=struct.unpack_from('<H',d,0x36)[0]; n=struct.unpack_from('<H',d,0x38)[0]; m=0
for i in range(n):
    o=off+i*es
    if struct.unpack_from('<I',d,o)[0]==1: m=max(m,struct.unpack_from('<Q',d,o+0x30)[0])
print('align',m,'OK' if m>=16384 else 'BAD')
PY
done
```

`libirondash_engine_context_native.so` が `BAD align=4096` なら、上の export / daemon 停止が効いていない。直してから upload すること。

