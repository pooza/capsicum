### 4.4 GitHub Release のリリースノート

#### 体裁は直前リリースを踏襲する

**リリースノートの体裁は「直前のリリースのリリースノート」が正本**。毎回同じ読み口にするのが目的なので、書き始める前に `gh release view v<直前>` で構成を確認してから起こす（v1.57 の初稿で体裁を外し、pooza から「いつものものに」と差し戻された）。

- 見出しは `## 新機能・改善` / `## 不具合修正` / `## その他` / `## Linux (AppImage)` / `## 既知の不具合（bug ラベル open Issue）`
- 各項目は **Issue タイトルの転記ではなく、太字の要点 + 「何がどう変わるか」の説明**で書く。Issue 番号は末尾に添える
- **`## 入手方法` のようなプラットフォーム列挙の節は作らない。** ストアバッジ等は公式サイト側の仕事で、リリースノートで列挙すると特定プラットフォームだけ強調する形になりやすい（メモリ `feedback_windows_store_no_special_emphasis` / `feedback_no_msix_sideload_in_release_notes`）。Linux セクションだけは §4.5 のとおり必ず入れる（ストア展開が無く、このワンライナーが最優先の導線のため）

#### 既知の不具合

「既知の不具合」セクションを作る場合は、ハードコードせず **bug ラベルが付いた open Issue を列挙** する。固定の文言は実態とズレるため、Issue が正本となるように書く。

```bash
gh issue list --label bug --state open
```

この結果をもとにリリースノートの「既知の不具合」を構築する。ただし **列挙するのはユーザーから見える不具合だけ**で、観測目的の Issue（Sentry 後継観測など）と再現待ちの Issue は落とす。

#### 公開状況の外形確認（App Store lookup API）

iOS / macOS の「審査提出済み」と「公開済み」の差は、Apple の iTunes Search API (lookup) で認証なしに確認できる。`currentVersionReleaseDate` が最新版のストア反映日時。

```bash
# iOS / iPadOS（bundleId は Universal Purchase 共通）
curl -sA "Mozilla/5.0" "https://itunes.apple.com/lookup?bundleId=jp.co.b-shock.capsicum&country=jp" | python3 -m json.tool

# macOS（Mac App Store、entity=macSoftware）
curl -sA "Mozilla/5.0" "https://itunes.apple.com/lookup?bundleId=jp.co.b-shock.capsicum&country=jp&entity=macSoftware" | python3 -m json.tool
```

注目フィールド: `version`（最新公開バージョン）/ `currentVersionReleaseDate`（ストア反映時刻 UTC）/ `releaseDate`（初公開日）/ `trackViewUrl`。

注意:

- User-Agent がないと空応答になることがあるため `-A "Mozilla/5.0"` を付ける。`country=us` 等で他ストアも確認できる
- **片方ストアが長期停滞中だと lookup の `version` が実態と乖離する**。Universal Purchase の `trackId` 共有の都合で、iOS と macOS のどちらか古い方の公開バージョンが優先表示されることがある（例: iOS が新版公開済みでも macOS が審査停滞中だと両 storefront とも古い方を返し続ける）。lookup は公開済みアプリの現行版しか返さないため、**審査中（`WAITING_FOR_REVIEW` / `IN_REVIEW`）かどうかや iOS / macOS の個別ステータスは原理的に分からない**

#### 審査ステータスのプラットフォーム別確認（App Store Connect API、推奨）

iOS と macOS の審査状態を**別々に正確に**取得するには App Store Connect API を使う（lookup では Universal Purchase の同一レコードを拾うため不可）。`appStoreVersions` を `platform`（`IOS` / `MAC_OS`）でフィルタすると各版に `appStoreState`（`READY_FOR_SALE` = 公開済み / `WAITING_FOR_REVIEW` = 審査待ち / `IN_REVIEW` = 審査中 / `PENDING_DEVELOPER_RELEASE` 等）が付く。**今後 iOS / macOS の公開状況確認はこの方法を第一とする**（lookup は補助）。

認証は fastlane と同じ ASC API Key（`~/.config/capsicum/AuthKey_<KEY_ID>.p8`）を流用し、ES256 JWT を生成して叩く（Ruby の `jwt` gem 利用）。`<KEY_ID>` / `<ISSUER_ID>` の実値は public リポジトリには書かず、各マシンの `~/.config/capsicum/` 配下と private な端末固有値リファレンスで管理する（このファイル冒頭 §1.3 と同じ方針）。実行前に環境変数へ入れておく:

```bash
# 実値は private リファレンス参照。例: export ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=........-....-....-....-............
ruby -e '
require "jwt"; require "net/http"; require "json"; require "uri"
KEY_ID=ENV.fetch("ASC_KEY_ID"); ISSUER=ENV.fetch("ASC_ISSUER_ID")
key=OpenSSL::PKey::EC.new(File.read(File.expand_path("~/.config/capsicum/AuthKey_#{KEY_ID}.p8")))
now=Time.now.to_i
tok=JWT.encode({iss:ISSUER,iat:now,exp:now+600,aud:"appstoreconnect-v1"},key,"ES256",{kid:KEY_ID,typ:"JWT"})
get=->(p){u=URI("https://api.appstoreconnect.apple.com/v1/#{p}");r=Net::HTTP::Get.new(u);r["Authorization"]="Bearer #{tok}";JSON.parse(Net::HTTP.start(u.host,u.port,use_ssl:true){|h|h.request(r)}.body)}
app=get.call("apps?filter[bundleId]=jp.co.b-shock.capsicum")["data"].first["id"]
%w[IOS MAC_OS].each{|pl|puts "== #{pl} ==";get.call("apps/#{app}/appStoreVersions?filter[platform]=#{pl}&limit=3")["data"].each{|v|a=v["attributes"];puts "  #{a["versionString"]}  #{a["appStoreState"]}"}}
'
```

#### Microsoft Store の公開確認（displaycatalog、認証不要）

Windows は Partner Center から pooza が手動 publish するため、Claude 側からは**認定が通って実際に差し替わったか**だけを外形で見る。ストアの公開カタログ API が認証なしで現行パッケージを返す（Store ID `9NP2GR7M2W6P` は[ストアページ](https://apps.microsoft.com/detail/9np2gr7m2w6p)の URL と同じ公開値）。

```sh
curl -s "https://displaycatalog.mp.microsoft.com/v7.0/products/9NP2GR7M2W6P?languages=ja-jp&market=JP" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['Product']['DisplaySkuAvailabilities'][0]['Sku']['Properties']['Packages'][0]['PackageFullName'])"
```

`9AFBB08E.capsicum_<version>.<build>.0_x64__8ekzzj58251a2` が返る。**提出直後はまだ前バージョンを返す**ので、ここが新しい版に変わって初めて公開完了と判定する（例: v1.58 なら `1.58.171.0`）。

#### Google Play production トラックの確認

`fastlane release` が意図したビルドを昇格したかは Play API で実測する（§4.2 の versionCode 衝突事故対策）。ASC と同じく service-account JWT を作り、`edits` を開いて `tracks/production` を読む。認証は `~/.config/capsicum/google-play-service-account.json`。

```sh
ruby -e '
require "json"; require "jwt"; require "net/http"; require "uri"
sa=JSON.parse(File.read(File.expand_path("~/.config/capsicum/google-play-service-account.json")))
key=OpenSSL::PKey::RSA.new(sa["private_key"]); now=Time.now.to_i
jwt=JWT.encode({iss:sa["client_email"],scope:"https://www.googleapis.com/auth/androidpublisher",aud:"https://oauth2.googleapis.com/token",iat:now,exp:now+3600},key,"RS256")
tok=JSON.parse(Net::HTTP.post_form(URI("https://oauth2.googleapis.com/token"),{"grant_type"=>"urn:ietf:params:oauth:grant-type:jwt-bearer","assertion"=>jwt}).body)["access_token"]
pkg="net.shrieker.capsicum"
call=->(m,p){u=URI("https://androidpublisher.googleapis.com/androidpublisher/v3/applications/#{pkg}/#{p}");r=m.new(u);r["Authorization"]="Bearer #{tok}";r["Content-Length"]="0" if m==Net::HTTP::Post;JSON.parse(Net::HTTP.start(u.host,u.port,use_ssl:true){|h|h.request(r)}.body)}
eid=call.call(Net::HTTP::Post,"edits")["id"]
call.call(Net::HTTP::Get,"edits/#{eid}/tracks/production")["releases"].each{|r| puts "production: versionCodes=#{r["versionCodes"]} status=#{r["status"]} name=#{r["name"]}"}
'
```

`status=completed` かつ `versionCodes` がそのリリースの build 番号なら製品版公開済み。⚠ **`edits` を開くだけなら Play 側に副作用は無い**（commit しなければ破棄される）。

> ⚠️ **darwin では `ruby` を叩く前に rbenv shims を PATH 先頭に置く**（非対話 shell だと macOS 同梱 2.6 や壊れた MacPorts に落ち、`jwt` gem が見つからず「確認できない」と誤認する）。`export PATH="$HOME/.rbenv/shims:$PATH"` してから `ruby -v` が 3.x であることを確かめる。

