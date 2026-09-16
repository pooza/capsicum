### 4.6 Windows 配布（v1.25〜）

Windows は fastlane を使わず GitHub Actions の windows-latest runner ジョブ ([.github/workflows/windows-release.yml](../../../.github/workflows/windows-release.yml)) でビルドする。**公式配布は Microsoft Store 単独**（[#760](https://github.com/pooza/capsicum/issues/760)、2026-07-02〜）:

- **Microsoft Store 経由** ([#544](https://github.com/pooza/capsicum/issues/544)、2026-05-20 初回審査通過): Partner Center Web UI からの **手動 publish** ルートで Store 公開。**Windows 唯一の公式配布ルート**（[apps.microsoft.com/detail/9np2gr7m2w6p](https://apps.microsoft.com/detail/9np2gr7m2w6p)）
- **自己署名 MSIX（draft Release 添付）は非公式・非サポート・案内しない**（[#423](https://github.com/pooza/capsicum/issues/423) の直配は #760 で表向き廃止、2026-07-05 に案内自体を全面停止、2026-07-19 にエンドユーザー向け `INSTALL.md` を削除）: CI は従来どおり `.msix` + `.cer` を draft Release に添付し**続ける**が、これは **pooza が Store 手動 publish 用に `.msix` を取り出す口**であって、エンドユーザー向けの配布経路ではない。**リリースノート・README・公式サイトのいずれでも import 手順を案内しない**（#599 の Store IAP が Store-install 版でしか動かず、直配版だと投げ銭できない非対称を避けるため）。内部ベータ / 開発検証用の import 手順は [install-internal-beta.ps1](../../../distribution/windows/install-internal-beta.ps1) に閉じる。Windows の配布は Microsoft Store 単独に一本化する

msstore CLI 経由の自動 publish は個人開発者アカウントから Entra ID テナント関連付け UI に到達できず引き続き保留。毎リリースの Store publish は **Partner Center Web UI から手動** が前提。

`pubspec.yaml` の `msix_config.store: false` のまま生成した自己署名 MSIX を Web UI に upload する経路で初回審査通過済み（Store 側で再署名されるため self-signed のまま submit 可）。Store 提出用の `.msix` は draft Release 添付（または CI の `capsicum-msix` artifact）から取り出して使う。

OV コード署名証明書 ([#534](https://github.com/pooza/capsicum/issues/534)) は Store 経由配布が唯一の公式ルートになったため不要（Store 経由は MS が再署名、自己署名直配は #760 で非公式化）。

#### Windows 内部ベータ提出（他 OS の TestFlight / Play 内部トラック相当・[#797](https://github.com/pooza/capsicum/issues/797)）

製品版を Store へ submit する前に、**release ビルドを実機で検証する経路**。iOS の TestFlight / Android の Play 内部トラックに対応する。v1.43 で投げ銭（[#599](https://github.com/pooza/capsicum/issues/599)）を release ビルド検証なしで製品版提出した反省（軽量な検証経路が未確立だった）から手順化した。検証内容に応じて 2 経路を使い分ける。

**A. CI artifact sideload（軽量・既定）** — ほとんどの release ビルド検証はこれで足りる。

CI（`windows-release.yml`）は tag 駆動に加え `packages/capsicum/windows/**` / `pubspec.yaml` 変更の PR でも走り、署名済み `capsicum.msix` + `.cer` を `capsicum-msix` artifact として出す（保持 14 日）。これを取得して信頼ストア import + `Add-AppxPackage` するまでを [install-internal-beta.ps1](../../../distribution/windows/install-internal-beta.ps1) が 1 コマンドに畳んでいる（cert import と install に管理者権限が要るため自動昇格する）:

```powershell
# develop の最新成功ビルドを取得してインストール（run 自動選択）
pwsh distribution/windows/install-internal-beta.ps1
# 特定の run を指定（artifact 保持は 14 日）
pwsh distribution/windows/install-internal-beta.ps1 -Run <run-id>
```

- **カバー範囲**: push 通知 / OAuth / ストリーミング / メディア再生 / UI / SMTC など **投げ銭以外のほぼ全機能**。OS 連携系（[#382](https://github.com/pooza/capsicum/issues/382) / [#559](https://github.com/pooza/capsicum/issues/559) のような native 連携）もこの経路で先行検証できる。
- **カバーしない**: **#599 投げ銭（Microsoft Store IAP）は動作しない**。自己署名 sideload 版はライセンスコンテキストが Store と異なり、`Windows.Services.Store` の購入は成立しない。IAP を触るリリースは経路 B を併用する。
- ARM64 Windows でローカル x64 ビルドが通らない制約（ATL / jni / crashpad）とも独立して回せる（CI 産の x64 MSIX を落とすだけ）。手動の `gh run download` → ダブルクリック運用（従来）を script 化したもの。

**B. MS Store package flight（IAP 検証が要るリリースのみ）** — Store-signed の実配布と同一バイナリで、実際の購入まで検証できる唯一の経路。

Partner Center の **package flight** は、本番 submission と別に限定テスターへ Store 経由で配る仕組み（TestFlight のサンドボックス購入に相当）。#599 投げ銭のように **Store-install 版でしか挙動しない機能**を release ビルドで検証するときに使う。

1. Partner Center → アプリ「capsicum」→ **Package flights** → 新規 flight を作成（テスターの MSA / AAD メールを flight group に登録）
2. draft Release 添付（または `capsicum-msix` artifact）の `capsicum.msix` を flight の Packages に upload（本番 submission と同じ MSIX でよい）
3. Submit for certification（本番より軽い審査）→ 通過後、テスターに配られる **flight 専用の Store リンク**からインストール
4. Store-install 版として起動し、投げ銭の購入ダイアログ〜消費報告まで実機確認

> Partner Center の UI 名称は変わりやすい。「Package flights」が見つからないときはアプリ概要から辿る。flight は本番審査より速いが、証明書認定は要るため経路 A より重い。
>
> ⚠️ **flight は「捨てアカウント」で受けること（2026-07-07 に実害）。** package flight の**テスターグループに登録した Microsoft アカウントは製品版（本番リング）を受け取れない**。flight package が本番より古いと、本番が新しくなってもそのアカウントは古い版に固着する。厄介なのは **submission を削除しても戻らない**点で、真の blocker は**テスターグループのメンバー登録**。wsreset / Store 再サインイン / アンインストール→再インストールのどれでも剥がれない（client 側では直せない）。v1.43 の投げ銭検証で日常アカウントをフライトに入れた結果、v1.44 公開後もそのアカウントが 1.43 に固着した（一般ユーザーは無風＝おま環）。**復旧は self-service**：Partner Center でそのアカウントを**フライトのテスターグループから外す**と製品版が installable になる（MS サポート不要。過度に恐れる必要はないが、submission 削除だけでは戻らない=使い勝手が悪い）。原則 **日常使いの Microsoft アカウントをフライトに入れない**。

**使い分けの原則**:

- 既定は **A（sideload）**。毎リリース、製品版昇格（§4.3）の前に回す。
- リリースに **#599 IAP を含む / Store-install 固有挙動を触る**場合は **B（flight）も**回してから submit する。**ただし flight は日常アカウントでなく捨てアカウントで受ける**（上記の固着を避けるため）。IAP の実購入検証がどうしても要るときだけ B を使い、それ以外は A で十分。
- どちらも `Add-AppxPackage` は同一 identity（`9AFBB08E.capsicum`）を置き換えるため、**Store 版を常用している端末では検証後に Store 版へ戻す**（sideload 版をアンインストール → Store から再インストール、または flight リンクから本番版へ）ことに注意。

#### MSIX

タグ駆動 (`v*.*.*`) で `windows-release.yml` の `msix` ジョブが起動し:

1. windows-latest (x64) で `flutter build windows --release`（jni transitive のため Microsoft OpenJDK 21 を `actions/setup-java` で導入）
2. Repository Secrets `WINDOWS_SELFSIGNED_PFX_BASE64` / `WINDOWS_SELFSIGNED_PFX_PASSWORD` から PFX を復元（未投入時は ephemeral cert にフォールバック、warning 出力）
3. `dart run msix:create --certificate-path ... --certificate-password ...` で **署名済み** `capsicum.msix` を生成（msix package が内部で signtool を呼ぶ）
4. PFX から公開鍵 `.cer` を抽出
5. `capsicum.msix` + `capsicum-signing.cer` を **draft Release** に添付（pooza が GitHub UI で publish 判断）

Microsoft Store への publish は msstore CLI 自動化が保留中のため、§「Microsoft Store 手動 publish の毎回手順」に従って Partner Center Web UI から手動で行う（同じ `capsicum.msix` を upload）。

draft で生成するのは「リリース作業の委託範囲」(自動公開はしない) ルールに従う。

#### 自己署名証明書の投入手順（一度だけ、[#423](https://github.com/pooza/capsicum/issues/423)）

PFX を Mac 側で生成して Repository Secrets に投入する。Subject は `pubspec.yaml` の `msix_config.publisher` (`CN=0B8EE9C3-CB07-4EBE-B8B8-B73E973AEE42`) と完全一致させる必要がある。

1. **PFX 生成** (Mac で openssl):

   ```sh
   # 任意のパスワードを決める
   PASSWORD="$(openssl rand -base64 24)"
   echo "$PASSWORD"  # 控える (secrets.env と同等の機密扱い)

   # 秘密鍵 + 自己署名証明書を生成 (5 年有効、Code Signing EKU)
   openssl req -x509 -newkey rsa:4096 -keyout capsicum-signing.key -out capsicum-signing.crt \
     -days 1825 -nodes \
     -subj "/CN=0B8EE9C3-CB07-4EBE-B8B8-B73E973AEE42" \
     -addext "extendedKeyUsage=codeSigning"

   # PFX (PKCS#12) にまとめる
   openssl pkcs12 -export -out capsicum-signing.pfx \
     -inkey capsicum-signing.key -in capsicum-signing.crt \
     -password pass:"$PASSWORD"

   # base64 化 (macOS では直接クリップボードへ)
   base64 -i capsicum-signing.pfx | pbcopy
   ```

2. **GitHub Repository Secrets に投入** (`https://github.com/pooza/capsicum/settings/secrets/actions`):
   - `WINDOWS_SELFSIGNED_PFX_BASE64`: 上記 base64 文字列
   - `WINDOWS_SELFSIGNED_PFX_PASSWORD`: 上記 `PASSWORD`

3. **生成物の保管**: `capsicum-signing.pfx` 本体と `PASSWORD` は **secrets.env と同等の機密扱い** で保管。再生成するとエンドユーザーが信頼ストアに再 import 必要になる。

投入後の最初のタグ駆動ビルドで `msix` ジョブが署名済み MSIX を生成する。

#### 自己署名 PFX の rotation / 失効対応 runbook

PFX は 5 年有効。**期限切れ・流出疑い・鍵管理ホスト退役のいずれかが発生したらローテーションする**。流出した場合、当該 cert で署名された任意 MSIX が既存ユーザーの `TrustedPeople (LocalMachine)` に対して auto-trust されるため、迅速な対応が必要。

ローテーション手順:

1. 上記「自己署名証明書の投入手順」を再実行し、新しい PFX を生成 → Repository Secrets を上書き
2. 次の通常リリース (または hotfix) で新 cert 署名 MSIX を draft Release に出す
3. 内部ベータ / 開発検証環境では、証明書ローテーション後の初回起動前に新 `.cer` を `TrustedPeople` に再 import する（[install-internal-beta.ps1](../../../distribution/windows/install-internal-beta.ps1) が import まで畳んでいる）。旧 `.cer` は `Cert:\LocalMachine\TrustedPeople` から該当エントリを削除する。**エンドユーザー向けのリリースノートには自己署名証明書の再 import 手順を書かない**（公式配布は Microsoft Store 単独で証明書 import は発生しない）

流出が確定した場合の追加対応:

- 旧 cert の Subject Key Identifier / Serial Number を release notes と [capsicum-site](https://capsicum.shrieker.net) にアナウンスし、エンドユーザーに `Cert:\LocalMachine\Disallowed` への追加 (`Set-Location Cert:\LocalMachine\TrustedPeople; Get-ChildItem | Where-Object {<対象cert>} | Move-Item -Destination Cert:\LocalMachine\Disallowed`) を案内
- OV cert 取得 (#534) を前倒しできるか検討。OV 経路に切り替われば自己署名 cert は不要になり、再発防止できる

`pubspec.yaml` の `msix_config.publisher` (`CN=0B8EE9C3-…`) を変更すると、Microsoft Store の identity 紐付け (#544) で再申請が必要になるため、ローテーション時の Subject 変更は避ける。

#### Microsoft Store 手動 publish の毎回手順（毎回・[#544](https://github.com/pooza/capsicum/issues/544)）

タグ駆動ビルドで draft Release に添付された `capsicum.msix` を Partner Center Web UI から手動で submission する。初回審査は 2026-05-20 通過、以降は同じ流れで毎リリース回す。

> 提出の前に §「Windows 内部ベータ提出」で release ビルドを実機検証してから publish すること（既定は sideload、#599 IAP を触るリリースは package flight も）。

1. **Partner Center にログイン**: <https://partner.microsoft.com/dashboard> → アプリ「capsicum」(`identity_name=9AFBB08E.capsicum` / `publisher_display_name=小石達也`)
2. **新規 Submission を開始**
3. **Packages**: draft Release に添付された `capsicum.msix` をそのまま upload（`msix_config.store: false` のままで OK、Store 側で再署名される）
4. **Submission Options > Notes for Certification**: 毎回必須。確定文面・根本原因・Windows 固有の注意は [msstore-review-notes-login.md](../../../docs/msstore-review-notes-login.md) を single source of truth とする（capsicum は OAuth + 外部サーバー前提のため、書かないと Policy 10.3.1 *App Is Testable - Test Account* で差し戻し）
5. **System Requirements (推奨環境)**: 「イマーシブヘッドセット」項目に **明示的にチェックを入れる**罠あり（実体としては不要だが、UI が空欄を許容せず submission に進めない仕様。2026-05-16 にはまった経緯あり、参考: <https://mstdn.b-shock.org/@pooza/116586587890264199>）
6. **Submit for certification**: Microsoft 公称の認定期間は最大 1-3 日（初回は 3-7 日）だが、**実績では問題がなければ 1 時間程度で通過することが多い**（Android と同様に速い）。数時間経っても Pending のままなら審査で引っかかっている可能性を疑う。通過後に Store listing が自動で publish される
7. **動作確認**: Store からインストールして SmartScreen 警告なしで起動できることを確認

msstore CLI 経由の自動 publish は個人開発者アカウントから Entra ID テナント関連付け UI に到達できず引き続き保留のため、毎リリース手動で行う。

#### Microsoft Store credential 投入手順（将来 msstore CLI 自動 publish が再開した時のみ）

現状は §「Microsoft Store 手動 publish の毎回手順」を毎リリース回しているため credential 投入は不要。将来 msstore CLI 自動 publish の再挑戦が成立した時点で、Repository Secrets `MS_STORE_CLIENT_ID` / `MS_STORE_CLIENT_SECRET` / `MS_STORE_TENANT_ID` を投入すると `windows-release.yml` の publish step が自動有効化される構造を残してある（現在 secrets 未投入時 skip 動作）。

#### GitHub Release のリリースノート（Windows セクションテンプレート）

タグごとの GitHub Release description に追記するテンプレート。pooza がドラフト Release を編集する際に貼り付ける。

> ⚠️ **自己署名 MSIX 直配はリリースノートに一切書かない**（2026-07-05 方針確定）。この配布方法は今後一切案内しない。CI は従来どおり `.msix` + `.cer` を draft Release に添付し続けるが（pooza が Store 手動 publish 用に `.msix` を取り出す口）、**リリースノート・README・公式サイト・INSTALL.md のいずれでも import 手順を案内しない**。Windows の公式配布は Microsoft Store 単独（#760 をさらに徹底）。

````markdown
## Windows

Microsoft Store からインストールできます: [apps.microsoft.com/detail/9np2gr7m2w6p](https://apps.microsoft.com/detail/9np2gr7m2w6p)
````

#### Windows ローカルビルド確認

```sh
cd packages/capsicum
flutter build windows --release
dart run msix:create  # 未署名で生成 (開発者モード ON の Windows でのみ動作)
# build/windows/x64/runner/Release/capsicum.msix
```

ローカル MSIX は未署名のため、Windows 側で「開発者モード ON」 (Settings → For developers → Developer Mode) の状態でのみ `Add-AppxPackage` できる。CI 経由の署名済み MSIX は信頼ストア import 後であれば開発者モード不要。

