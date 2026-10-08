# 有償プッシュリレー（#597）— 現状の棚卸し（実測）

[paid-relay-plan.md](paid-relay-plan.md) の「決定済み事項 1」を独立させたもの（#1184・2026-09-30）。⚠ **設計書が #597 の進行で伸び続けるので、実測の側を分けた。**決定と未決は本体にある。

⚠⚠ **節番号は本体と同じ 1-1〜1-6 のまま。**振り直していない（本体・[product-policy.md](product-policy.md) が番号で参照している）。

⚠⚠ **これは「着手前の状態」ではなく、いまも効く前提。**特に次の 2 つは 2026-09-28 に再確認されている:

- **1-2 の「プリセット 1 アカウントで全部無償」は完全に意図通り**（**不具合として直す提案をしないこと**）
- **プリセットサーバーのアカウントを 1 つも持たない利用者は 0 人**（`device_id` で畳んだ実測）

⚠ **1-1 / 1-2 の「認可は無い」「プリセット判定はクライアント側にしかない」は、その後 relay 側で塞がれた**（[relay#60](https://github.com/pooza/capsicum-relay/issues/60) 認可ゲート / [relay#69](https://github.com/pooza/capsicum-relay/issues/69) `/push` の VAPID 署名で裏取り）。**ここに書いてあるのは設計の出発点としての実測**で、現在の relay の姿ではない。

## 1. 現状の棚卸し（実測）

### 1-1. relay の認証は共有シークレット 1 本。認可は無い

```ruby
# capsicum-relay/lib/relay/base_app.rb:120
def authenticate!
  secret = settings.config['shared_secret']
  provided = request.env['HTTP_X_RELAY_SECRET']
  return if provided == secret
  ...halt 401
end
```

- **全エンドポイントがこれだけ**（`/register` / `/push` / `/supporters` / `/announcement_subscriptions`）
- ⚠⚠ **このシークレットは全クライアントに配られている。**`--dart-define=RELAY_SECRET` でビルド時に**バイナリへ埋め込まれる**（[dev-environment.md](dev-environment.md)）。**取り出せる**
- → **現状は「capsicum を持っている人は誰でも relay を使える」。**無償サービスなので実害が小さいだけで、**課金を始めた瞬間に、迂回する経済的動機が生まれる**

⚠ **共有シークレットを廃止する必要は無い**（API 面の粗いフィルタとしては働く）。**認可の境界として使うのをやめる**、が正しい。

### 1-2. プリセット判定はクライアント側にしかない。しかも意図的な穴がある

```dart
// capsicum/lib/src/service/push_registration_service.dart:129
if (!eligible && !isPresetServer(account.key.host)) { /* skip */ }
```

`eligible` は [`hasPresetAccountProvider`](../packages/capsicum/lib/src/provider/account_manager_provider.dart) ＝ **プリセットのアカウントを 1 つでも持っていれば true**（⚠ 接続できていないアカウントも数える。当初は `hasPresetAmong` が接続できたアカウントだけを数えており、2026-10-06 の差分レビューで置き換えた）。

⚠⚠ **つまり「プリセットに 1 アカウント持てば、外部サーバーのアカウントも全部無償でリレーされる」。**これはバグではなく doc コメントに明記された仕様（「プリセットサーバーのアカウントを1つでも持っていれば、全アカウントを登録対象とする」）。

→ ⚠⚠ **有償化したとき、この穴が有償商品を素通りさせる。**⚠ **これが本件で最も重い設計上の論点**（未決事項 3）。

⚠⚠ **この挙動は「完全に意図通り」**（2026-09-28 pooza）。**不具合として直す提案をしないこと。**穴の扱いは未決事項 3 で決着しており、**2026-09-28 の再評価でも決定（a = 穴を残す）は変えていない。**

⚠⚠ **穴は実際に通られている。ただし通っているのは「外部ユーザー」ではない**（2026-09-06 実測・本番 DB の `subscriptions`）。

**サーバー別に数えると外部が 3 分の 1 を占める**（158 サブスク・24 サーバー・ios 64 / android 50 / windows 29 / macos 15）:

| | サブスク数 | 内訳 |
| --- | --- | --- |
| プリセット 5 サーバー | 93（59%） | delmulin 33 / misskey.delmulin 20 / precure.ml 19 / mk.precure.fun 15 / b-shock 6 |
| 外部サーバー | 57（36%） | fedibird 10 / foresdon 7 / misskey.io 6 / auroraplanet 6 / pawoo 4 ほか |
| ステージング | 8 | 検証用 |

### しかし「人」で数えると、プリセット非保有の利用者は **0 人**

**⚠⚠ サーバー別の数字を「外部ユーザーが 36%」と読むのは誤り**（2026-09-06 に一度そう書いて pooza に否定された）。**capsicum の利用者はマルチアカウントが多い**ので、**外部サーバー宛の 57 件は、プリセットにもアカウントを持つ同じ人たちのもの**。

⚠ **`device_id` で端末単位に畳んで数え直した結果**:

| | 端末数 | サブスク数 |
| --- | --- | --- |
| **プリセットのアカウントを 1 つ以上持つ** | **34** | 119 |
| ⚠ **プリセットを 1 つも持たない** | **1** | 1 |

⚠⚠ **その 1 件も偽陽性だった。**中身は `st2.misskey.delmulin.com`（**自前のステージング**）で、判定リストに `st2.*` を入れ忘れていただけ。`token` 単位で数え直しても同じ（51 token が preset 持ち・「外部のみ」はこの 1 件のみ）。

→ ⚠⚠ **現時点で、プリセットサーバーのアカウントを 1 つも持たない利用者は 0 人。**

**この事実が #597 の前提を決める**:

- ⚠ **「既に外部へ届けているものに対価を求める」という話ではない。**届けている相手は**全員プリセットのメンバー**
- ⚠⚠ **有償化の対象は「これから来る人」。需要は未証明**（実測値ではなく仮説）
- ⚠ **未決事項 3（穴を塞ぐか）の意味も変わる。**塞いでも**止まる利用者は 0 人**だが、**マルチアカウント利用者の外部アカウント宛 57 件が止まる**。⚠ **非目標に当たるのはこちら**
- ⚠ **`device_id` は 2026-08-06 導入なので 38 行が `null`。**うち外部サーバー宛は 7 行（maniakey 2 / fedibird 2 / vivaldi 1 / misskey.cloud 1 / foresdon 1）。⚠ **`token` 単位の集計でも「外部のみ」は増えなかった**ので、結論は変わらない

### 1-3. `supporters` は自己申告の記録。レシート検証はどこにも無い

```ruby
# capsicum-relay/lib/relay/routes/supporters.rb
post '/supporters/tip' do
  authenticate!
  require_fields!('account', 'server')
  ... record_supporter_tip(...)   # ⚠ 検証なし
end
```

- スキーマは `supporters(account, server, first_tipped_at, tip_count, last_sku, ...)`（`database.rb:184`）
- ⚠ **`grep receipt` は relay / capsicum とも 0 件。**[supporter-subscription-plan.md](supporter-subscription-plan.md) B-4 の「レシート検証は最小（ストアを信頼）」がそのまま出荷されている
- **装飾バッジとしては妥当な判断**（偽っても得るのはバッジだけ）。⚠ **課金ゲートとしては成立しない**（`X-Relay-Secret` を付けて POST するだけでサポーターになれる）

### 1-4. レシートは手元まで来ているが、抽象化の境界で捨てている

`SupporterPurchaseEvent`（[supporter_purchase_backend.dart:26](../packages/capsicum/lib/src/provider/supporter_purchase_backend.dart)）が持つのは **`productId` だけ**。`in_app_purchase` の `PurchaseDetails.verificationData.serverVerificationData` は**この境界で落ちている**。

⚠ **これは良い知らせ。**取得経路は既にあり、**抽象層の 1 フィールドを増やすところから始められる**（作り直しではない）。

### 1-5. ⚠ スケールの階段 — 先に効くのは同時実行数、その次にプラン

**2026-09-06 に本番 relay ホスト上で実測した**（relay のログ 7 日分 4,108 件の `latency_ms` と本番 DB）。

⚠⚠ **初稿の「詰まるのは RAM ではない」は論点のすり替えだった**（2026-09-06 pooza の訂正）。**VPS はメモリ容量でプラン全体（CPU コア数・帯域）が決まる慣習**なので、「1GB では耐えられなくなる」は**プランを上げることになる**という意味であって、RAM 単体の話ではない。⚠ **「1GB」はプラン名であって症状名ではない。**下の階段は「プランを上げる前にやれることがある」という話で、**プランを上げる日が来ないという主張ではない**。

| 指標 | 実測 |
| --- | --- |
| ホスト | 本番 relay ホスト = **1GB プラン**（load average **0.00**・素性の正本は chubo2 `docs/infra-servers.md`） |
| relay プロセス | RSS **約 65MB**。DB は SQLite で **335KB**（WAL 4MB） |
| ⚠ **同時実行数** | ⚠⚠ **puma は `workers 0` / `threads 2`。同時に 2 通しか捌けない** |
| 配送レイテンシ | **p50 168ms / p90 3,227ms / p99 4,581ms / max 8,976ms** |
| ピーク流入 | **21 通/分**（7 日間の最大・0.35 通/秒） |

⚠⚠ **p90 が p50 の 19 倍なのは Windows（WNS）**。実測ログで iOS が 173〜174ms のところ、WNS は **3,722ms** かかっている。**遅い 1 通が 2 本しかないスレッドの片方を 3.7 秒間占有する。**

#### device_type 別の負荷 — Windows が処理時間の 88% を占める

⚠⚠ **7 日間の `push.result` を device_type 別に集計した**（2026-09-06 実測）:

| OS | 件数 | 件数シェア | **総処理時間** | **時間シェア** | 平均 | ⚠ **非 success** |
| --- | --- | --- | --- | --- | --- | --- |
| ⚠⚠ **windows** | 398 | 32% | ⚠⚠ **818.3 秒** | ⚠⚠ **88%** | **2,056ms** | ⚠⚠ **260 件（65%）** |
| ios | 660 | **54%** | 83.4 秒 | 9% | 126ms | 94 件（14%） |
| android | 157 | 13% | 27.5 秒 | 3% | 175ms | 12 件（8%） |
| macos | 2 | 0.2% | 0.3 秒 | 0.03% | 141ms | 0 |

⚠⚠ **1 件あたりの重さは iOS の 16 倍。**⚠⚠ **さらに Windows は 3 分の 2 が非 success** — **時間の 88% を使って、その大半が届いていない**。

⚠ **この失敗は既に Sentry に出ている**: `CAPSICUM-RELAY-7`（WNS notification dropped・**4,476 件**）/ `CAPSICUM-RELAY-5`（oversized dropped・496 件）/ `CAPSICUM-RELAY-6`（delivery failed・88 件）。

#### `dropped` の正体 — dedup ではなく「端末が落ちている」

⚠⚠ **relay 側のコメント（[`push_helpers.rb`](https://github.com/pooza/capsicum-relay/blob/main/lib/relay/push_helpers.rb) `WNS_BENIGN_STATUSES`・relay#24 の調査で書かれたもの）が正本**:

> `dropped` は「端末がオフライン / スリープで受け取れなかった」で、**raw notification は queue されないため必ずこうなる**。**PC を消している時間の方が長い利用者ほど**通知量に比例して積み上がる

- ⚠⚠ **クライアント側の `notification.id` dedup（streaming と native push の併存）とは無関係。**dedup はアプリまで届いてから効く話で、**届いた時点で WNS は `received` を返している**
- → ⚠ **「つけっぱなしだから捨てられる」のではなく、逆に「消えている / スリープだから捨てられる」。**⚠ **つけっぱなしなら `success` になる**
- **実測（7 日・windows のみ）**: `wns_dropped` **260** / `success` **137** → ⚠ **対象の Windows 端末は 3 分の 2 の時間、落ちているかスリープしている**
- ⚠⚠ **raw は queue されないので、その間の通知は失われる**（後から届かない）。これは #474 の設計上の既知事項

#### 訂正: 失敗配送を減らしても軽くはならない

⚠⚠ **初稿は「WNS の失敗配送を減らせば 818 秒が 3 分の 1 になり容量が倍以上」と書いた。誤り**（2026-09-06 に outcome 別のレイテンシを測って判明）:

| outcome | 件数 | 総時間 | **平均** |
| --- | --- | --- | --- |
| `wns_dropped` | 260 | 527.2 秒 | **2,028ms** |
| `success` | 137 | 290.5 秒 | **2,120ms** |

⚠⚠ **成功しても 2.1 秒かかる。**`dropped` が遅いのではなく、**WNS への往復そのものが遅い**（APNs の 126ms に対して 17 倍）。→ **`dropped` を `success` に変えても総時間は変わらない。**

**効く打ち手は別のところにある**:

#### 2,056ms の内訳 — 3 分の 1 は「毎回 TLS を張り直している」ぶん

⚠ **本番 relay ホストから実測した**（2026-09-06）:

| 宛先 | DNS | TCP connect | **TLS 完了** | total |
| --- | --- | --- | --- | --- |
| **`db5p.notify.windows.com`**（WNS チャネル） | 7ms | **231ms** | ⚠⚠ **690ms** | 1,137ms |
| `login.live.com`（OAuth） | 2ms | 3ms | 34ms | 218ms |

⚠⚠ **WNS のチャネルは `db5p` = ダブリン（欧州）にある。**日本から **RTT 230ms**。⚠ **どの region に置かれるかは Microsoft 側の割り当てで、こちらでは選べない**（OAuth の `login.live.com` は国内エッジに載っていて 34ms なので、遅いのはチャネルのほう）。

**そして relay は 1 通ごとに接続を張り直している**:

```ruby
# capsicum-relay/lib/relay/wns_client.rb#post_raw
return Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
  http.request(request)
end
```

- ⚠⚠ **`Net::HTTP.start` を毎回呼ぶ = 1 通ごとに TCP 3-way + TLS ハンドシェイク。**上の実測で **690ms**、平均 2,056ms の **約 34%**
- ✅ **APNs は違う** — [`apns_client.rb`](https://github.com/pooza/capsicum-relay/blob/main/lib/relay/apns_client.rb) は **`Apnotic::Connection`（永続 HTTP/2）**を保持している。⚠ **126ms で済んでいるのはこれが理由**
- ⚠ FCM も `Net::HTTP.start` を毎回呼んでいるが **175ms**。Google のエッジが国内にあるため接続確立が安い。→ ⚠ **「毎回張り直す」実装が痛いのは、宛先が遠い WNS だけ**
- ⚠ **OAuth トークンは既にキャッシュ済み**（`TOKEN_EXPIRY_MARGIN` 付き）。**ここは犯人ではない**

#### 打ち手

**⚠ 3 本とも 2026-09-06 に relay へ起票済み。**

| | 打ち手 | Issue | 効き | いつ |
| --- | --- | --- | --- | --- |
| 1 | ⚠⚠ **WNS 接続の再利用**（keep-alive / プール） | [relay#54](https://github.com/pooza/capsicum-relay/issues/54) | **最大 34%**（690ms/通）。⚠ **APNs と同じ形に揃えるだけ** | ⚠ **今すぐ・単独**（変更が `post_raw` に閉じる） |
| 2 | **配送の非同期化**（1-5 の階段 2） | [relay#55](https://github.com/pooza/capsicum-relay/issues/55) | ⚠ **本命。**遅さは消えないが、**受信経路を塞がなくなる** | ⚠ **#597 のフェーズ 1〜2 と同じ回**（どうせ relay を触る） |
| 3 | **`dropped` を返した端末へのバックオフ** | [relay#56](https://github.com/pooza/capsicum-relay/issues/56) | **送信回数を 65% 減らせる**（527 秒ぶん） | ⚠ **on-hold。**1 と 2 の後に測り直してから判断 |
| — | ~~失敗を減らす~~ | — | ⚠ **効かない**（上の表） | — |

⚠ **1 と 2 で足りるなら 3 のリスク（起動直後の通知が来ない）を取る必要がない**ので、**3 は測ってから決める**。⚠ **測り直しの手順はこの節そのもの**（device_type 別の総処理時間）。

⚠ **言語の変更では解決しない**（2026-09-06 検討）。2 秒の内訳は接続確立 690ms + 往復と WNS 処理 1,370ms で、**どちらも言語に依存しない**。⚠ **Ruby の GVL は I/O 待ちで解放される**ので、ネットワーク待ちの並行は現状でもできる（`load average 0.00` が示すとおり relay は暇なまま待っている）。⚠ **言語差が効くのは「同時実行を数千に上げたい」領域**で、ピーク 21 通/分の 100 倍でも Ruby のスレッドで足りる。**書き換えのコストに見合わない**（mulukhiya と運用が揃っている利点も失う）。

⚠⚠ **ただし 1 + 2 + 3 を全部やっても、1 通 2 秒が APNs 並みの 126ms にはならない。**残る約 1,370ms は**日本 ↔ ダブリンの往復と WNS 側の処理**で、**relay の実装では動かせない**。

→ ⚠⚠ **1-5 の「階段」の主因は利用者数ではなく Windows**、という結論は変わらない。⚠ **ただし理由は「失敗が多いから」ではなく「WNS が本質的に遅いから」。**

**容量の見積もり**（現在の device_type 構成 = windows 18% で加重平均すると 1 通あたり約 0.77 秒）:

- 理論容量 ≒ **2 スレッド ÷ 0.77 秒 = 約 156 通/分**
- 実測ピーク **21 通/分 = 容量の約 13%**
- → ⚠ **飽和は現在の 7〜8 倍。サブスク 158 件に対して 1,200 件前後が目安**

⚠⚠ **ただし Windows 比率が上がると容量が急落する。**仮に全員 Windows なら 2 ÷ 3.5 秒 = **34 通/分**しか出ず、**現在のピーク 21 通/分に対して 1.6 倍の余裕しかない**。⚠ **「利用者が何人か」より「どの OS か」で先に詰まる。**

**次の段は「お金」ではなく「実装」**（順に安い）:

| 順 | 打ち手 | 費用 | 効き |
| --- | --- | --- | --- |
| 1 | **`threads` を 2 から上げる** | **0 円** | ⚠ **配送は外部 API の I/O 待ちが支配的**なので、1 vCPU でもほぼ線形に伸びる。**今の設定が保守的すぎる** |
| 2 | **配送を非同期化**（受信して即 202、送信はワーカー） | 実装のみ | 遅い WNS が受信経路を塞がなくなる |
| 3 | **`workers` を増やす** | 0 円 | ⚠ **1 vCPU なので効果は限定的**。メモリには余裕がある（65MB × N） |
| 4 | **プランを上げる** | ⚠ **ここで初めて費用が増える** | コア数・帯域が上がる（⚠ **メモリ容量でプランが決まるので、実質「1GB → 2GB → 4GB」という刻み**） |

⚠ **したがって「人数が増えたら VPS 代が上がる」は、1〜3 を使い切った後の話。**⚠ **逆に 1〜3 を放置したまま増員すると、プランを上げても直らない**（load average 0.00 のホストで「重い」が起きている状態は、コアを足しても `threads 2` のままなら変わらない）。

⚠ **「重い」の実体は CPU 仕事ではなく待ち時間。**p90 の 3.2 秒はほぼ全部が **WNS の応答待ち**で、relay 自身は暇（load average 0.00）。⚠ **待ちは並行数で吸収するものなので、まず 1〜2 が効く。**ただし Ruby の GVL があるため**復号など CPU を使う部分は並行しない** — ⚠ **1 を入れた後にもう一度実測して、どこで頭打ちになるかを見ること**（机上で断定しない）。

### 1-6. ⚠⚠ モロヘイヤ非導入の Misskey では、そもそも Web Push を購読できない（2026-09-28 追記）

**売り先は「モロヘイヤ非導入の Mastodon 系」に限られる。**本書はここまで「外部サーバー」を一括りに扱っていたが、**Misskey は技術的に対象外**である。

| | 購読の経路 | 外部サーバーで成立するか |
| --- | --- | --- |
| **Mastodon 系** | `POST /api/v1/push/subscription`（`push` スコープ） | ✅ **成立する**（fedibird / foresdon / pawoo など） |
| **Misskey 本家** | `POST /api/sw/register` | ⚠⚠ **成立しない** |
| Misskey + モロヘイヤ | `POST /mulukhiya/api/sw/register`（v5.19.0〜） | ✅ 成立するが、**それはプリセット側の話** |

⚠ **理由は relay ではなく Misskey 本家の仕様。**GHSA-7pxq-6xx9-xpgm（2023-12）の対策で `/api/sw/register` が `secure: true` に制限され、**MiAuth / OAuth のアクセストークンからは叩けない**（`{error: {code: 'ACCESS_DENIED'}}`）。capsicum は 400 / 403 / 404 をまとめて `PushRegistrationNotSupportedException` に倒している（#365 / #705・`misskey.io` ほかで実測・Sentry `CAPSICUM-1T`）。モロヘイヤの `/mulukhiya/api/sw/register` は**この制限の代替経路**として作られたもの（mulukhiya#4254）。

⚠⚠ **1-2 の「外部 57 サブスク」を市場規模として読まないこと。**`subscriptions` の行は **`/register` の時点で作られる**（fedi 側の購読登録はその後）ので、**行があっても配送が成立しているとは限らない**。内訳の `misskey.io` 6 件は**登録だけで配送が無い行**の可能性がある。⚠ **値付けや損益分岐（決定済み事項 6）の人数を見直すときは、`server` が Misskey のものを除いて数え直す。**

#### capsicum 側の方針 —— **開いたらそのまま使う。追加料金は求めない**（2026-09-28 pooza）

> もし Misskey 側がサードパーティクライアントにプッシュ通知を許すなら、**こちらも止めません**。**Misskey 対応に追加料金を求めるようなこともありません。**いま、Misskey で利用できない状況について、**ボールはあちらが握っている**ということです。（2026-09-28 pooza）

- ⚠ **制約が外れたら、そのまま対象に入る。**capsicum 側に制限を足したり、Misskey を明示的に除外したりしない。⚠ **`PushRegistrationNotSupportedException` は「上流が拒んだ」を素直に反映しているだけ**で、こちらの方針ではない
- ⚠⚠ **プラットフォーム別の価格階層を作らない。**月額 ¥200 の**単一階層**（決定済み事項 5）は維持する。「Misskey 対応は別料金」「Misskey は割引」といった案を出さない
- ⚠ **こちら側に打ち手は無い。**上流の仕様が変わるかどうかの問題なので、**回避策の実装を企図しない**（モロヘイヤ経由は既にあり、それはプリセット側の話）
- ⚠ **したがって 1-6 は「いまの対象範囲」の記録であって、恒久的な非目標ではない。**上流が変われば market の前提ごと変わる

#### 買う前に知らせる（2026-10-06 pooza）

⚠⚠ **有償で外へ出すと、立場が変わる。**1.x では、モロヘイヤの無い Misskey の利用者は「身内がそれを知ったうえで勝手に使っている」立場だったので、届かないことを説明する必要が無かった。**利用権を売ると、知らずに買う人が出る** —— 未購入の非プリセットのアカウントは登録を試みないので、「対応していません」と分かるのは**月額を払ったあと**になる。

→ **3 か所で、濃さを変えて知らせる。**全員に説明するのではなく、関係する人に関係する場面で出す。

| 場所 | 中身 |
| --- | --- |
| アプリの利用権の節 | **モロヘイヤの中継が無い Misskey のアカウントを持つ人にだけ**、アカウントを名指しして「購入しても届きません」と出す（`PushRegistrationService.pushUnavailableByServerSpec` / `relayUnsupportedAccountNote`） |
| capsicum-site `/push-notification`「利用対象」 | 1 段落。同じページの「Mastodon と Misskey の違い」へ送る |
| 特定商取引法に基づく表記 | 提供条件として 1 行 |

- ⚠ **購入は止めない。**同じ端末に届くアカウントが別にあれば利用権には意味があり、上の「capsicum 側に制限を足さない」とも食い違わない。出すのは注意書きだけ
- ⚠⚠ **上流が開放したら、アプリ内の判定と文面を外す。**判定は登録処理の分岐と同じ条件で書いてあるので、登録側を変えた回に一緒に見る。⚠ 外し忘れると、届くのに「届きません」と言い続ける
- ⚠ **プリセットの利用者には出さない**（購入の話をしない・[#1232](https://github.com/pooza/capsicum/issues/1232)）。届かないアカウントがあること自体は、プッシュ通知設定のアカウント行が伝える

#### 2026-09-28 の調査 —— 制約の実体と他クライアントの実態（⚠⚠ **方針の追加・変更は無い**）

> ここまでさんざん議論したこともあり、**ぞーぺんの状況だけは既知ではなかった情報**でした。**従来の方針に、追加や変更を検討すべき価値がある発見はなかった**と思います。（2026-09-28 pooza）

⚠⚠ **この節は「同じことを調べ直さないための記録」であって、方針を足すものではない。**

##### (1) `secure: true` の実体は「公式クライアントだけ」ではなく「**ネイティブトークンだけ**」

Misskey 本家のソースで確定（pooza/misskey フォーク・2026.9.1+1）。

```ts
// packages/backend/src/server/api/ApiCallService.ts:362
const isSecure = user != null && token == null;
if (ep.meta.secure && !isSecure) throw new ApiError(accessDenied);
```

| トークン | 長さ | `AuthenticateService.authenticate()` の戻り | `secure: true` |
| --- | --- | --- | --- |
| **ネイティブトークン** | **16 文字**（`generateNativeUserToken` = `secureRndstr(16)`） | `[user, null]` | ✅ **通る** |
| MiAuth | 32 文字（`miauth/gen-token.ts:58`） | `[user, accessToken]` | ❌ |
| OAuth / アプリ | 32 文字（`auth/accept.ts:62`） | `[user, accessToken]` | ❌ |

⚠ **ネイティブトークンは `POST /api/signin`（ID + パスワード）が `i: user.token` として返す**（`SigninService.ts:63`）。→ ⚠⚠ **パスワードログインを採れば、サードパーティでも `sw/register` は通る。**

⚠⚠ **ただし capsicum は採らない。****既存の方針で答えが出ているので、未決事項に立てない。**

- ⚠ **ネイティブトークンはユーザーにつき 1 本の master credential。**スコープが無く（`write:account` のような限定ができない）、⚠⚠ **個別に失効できない** —— `i/regenerate-token` はその 1 本を差し替えるので、**失効させると本人の Web UI も他アプリも全部切れる**
- ⚠ **本書 2-A / 2-C の「relay は復号しない / 資格情報を持たない」という柱**と、capsicum が MiAuth を使っている現状に、そのまま反する

⚠ **したがって上の「こちら側に打ち手は無い」は、厳密には「代償を見て選ばない」である。**⚠⚠ **区別はするが、結論は変わらない。**

##### (2) モロヘイヤの経路は **DB へ直接 INSERT** ＝ サーバー運営者にしかできない

> 現時点の例外は Misskey の `sw_subscription` のみ（`/api/sw/register` が重複行を溜め、それを修復する API が存在しないため）
> —— mulukhiya `README.md`（**非 SELECT の唯一の例外**として明記）

→ ⚠⚠ **構造的にプリセットへ閉じる。クライアント側の工夫では外へ出せない。**

##### (3) ⚠ **ぞーぺん（ZonePane）も Misskey の push は実現していない**（← この調査で唯一の新情報）

App Store の機能説明（2026-09-28 時点）:

| サービス | Push 方式 | Streaming（WebSocket） | 自動更新（定期取得） |
| --- | --- | --- | --- |
| **Mastodon** | ✅ ⚠ **Basic / Pro プラン限定** | ✅ | ✅ |
| **Misskey** | ❌ **記載なし** | ✅（⚠ **電池消費が増える**と注記） | ✅ |
| Bluesky | — | — | ✅ |

- ⚠⚠ **`secure: true` の壁を抜けた実例は見つからなかった。**抜けられないので **streaming 常駐とポーリングで埋めている**。→ **Misskey の穴は業界共通で、capsicum の競争上の不利ではない**
- ⚠ **先行事例は Mastodon の push を有料プランに載せている。**[#597](https://github.com/pooza/capsicum/issues/597) の有償化そのものの傍証にはなる。⚠⚠ **ただし料金が公開情報に無いので、値付け（決定済み事項 5 の ¥200）の根拠には使わない**

##### (4) ⚠ ポーリングは capsicum の選択肢にならない（実測済み・再検討しない）

**#293 の観測性強化で iOS の BGTaskScheduler が発火回数 0 回**と判明し、**v1.19（#348）で workmanager ごと撤去済み**（`docs/archive/push-relay-plan.md`）。

⚠ **streaming 常駐なら Android に余地はある**（デスクトップは #569 で既に streaming → OS ローカル通知を持つ）。⚠ **ただし iOS は常駐できず、電池も食う。**⚠⚠ **いずれも #597 のスコープ外**（有償リレーは push の話）。⚠ **Android の `OAuthKeepAliveService` は OAuth ログイン中だけの keep-alive で、streaming 用ではない**（転用は新規作業）。


