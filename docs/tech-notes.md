# 技術的知見・落とし穴集

実装中に発見した Flutter / Dart / 各種 API の落とし穴と回避策。コードコメントに残すほどではないが、失うと同じ地雷を踏む知見を集約する。

⚠⚠ **落とし穴集は 3 ファイルに分かれている**（#1184・2026-09-30）。**追記するときはこの表で行き先を選ぶ。**

| ファイル | 置くもの |
| --- | --- |
| **このファイル** | Dart / Flutter の実装（State・描画・`go_router`・テスト）・体感速度・Sentry の読み方・デスクトップの drag & drop・認証フロー |
| [tech-notes-native.md](tech-notes-native.md) | ネイティブプッシュ（APNs / WNS）と CI / ビルド（シェル・PowerShell・Windows ネイティブの検証手順） |
| [tech-notes-api.md](tech-notes-api.md) | サーバー API の罠（NodeInfo / Probing・Mastodon・Misskey・モロヘイヤ） |

⚠ **迷ったらこのファイルに置く。**あとで動かせる。⚠⚠ **1 ファイル 60,000 バイトが上限**（[doc-maintenance.md](doc-maintenance.md)「1 ファイルは 1 回で読める大きさに収める」）。分けたのは**この上限に貼り付いて追記がためらわれる状態をやめるため**で、3 つとも余白がある。

## Dart / Flutter 一般

### `firstWhere + orElse: () => null` は避ける

`List<dynamic>.firstWhere` に `orElse: () => null` を渡す書き方は型安全でないため、手動 for ループに置換する方が安全。

### 行の State に「隠す」フラグを bool で持たない（キー無しリストの State 再利用）

タイムラインのようなリストで、行ウィジェットの `State` に `bool _deleted` のような**その行を隠すフラグ**を持たせてはいけない。`ListView` / `ScrollablePositionedList` の各行に `key` が無いと、**Flutter は State を「位置」で再利用する**。先頭に要素が挿入されると、それまで A を描いていた State が B を描くようになり、そこへ A 由来の `setState(() => _deleted = true)` が走ると **B が隠れる**。`didUpdateWidget` で id 変化を見てリセットしていても、**フラグを立てるのが id 変化より後**なら復帰の機会が無い。

必ず **`String? _hiddenPostId` のように対象の id で持ち、`_hiddenPostId == widget.post.id` のときだけ隠す**。ブースト経由の操作は対象が内側の投稿になるので `reblog?.id` とも突き合わせる。

#909 で実際に踏んだ。「削除してタグづけ」はモロヘイヤが **Misskey では投稿→削除の順**で行うため、HTTP レスポンスが返る前に streaming が再投稿を先頭へ挿す。その結果、元投稿は `removePost` でデータから消え、再投稿は `_deleted` で描画から消え、**両方いなくなった**。原因が取り込み処理に見えて実は描画側だったため切り分けに時間がかかっている。通常の削除・削除して再編集・NowPlaying 削除でも同じ構造なので、**削除直後に新着が届けば無関係な投稿が消える**。

**根本対処として各行に `ValueKey(post.id)` を付ける場合は、そのリストの `loadMore` が重複排除しているかを先に確認する。** ページ境界やレースで同じ id が二重に入ると `Duplicate keys found` で描画ごと落ちる。capsicum では home / hashtag / list / channel の 4 つとも `[...posts, ...older]` で無防備だったので、キーと同時に dedup を入れた。streaming の先頭挿入が無い画面（ブックマーク / クリップ / アンテナ / 検索 / プロフィール）は本症状が起きないので、`loadMore` を監査するまでキーを付けない。

### `WidgetSpan` 内で `width: double.infinity` は使わない

親 `Text` の制約を超えるレイアウトエラーになる。自然幅（指定なし）で組むこと。iPad の広い画面で `RenderFlex` overflow を起こした実績あり（#60）。

### 背の高い `WidgetSpan` の直後に `TextSpan('\n')` を置かない（ブロック直後の空白）

`content_parser` はコードブロック・引用などブロック要素を `WidgetSpan` として `Text.rich` に埋め込み、前後を `TextSpan('\n')` で挟んで単独行に落としている。このとき **背の高い `WidgetSpan` の直後の `\n` が、行の下側にブロック高ぶんの空白を作る**（Flutter の WidgetSpan + trailing newline 既知挙動）。`alignment`（bottom/middle）・横スクロール・`Column` の `mainAxisSize` はいずれも無関係で、中身ゼロの固定高ボックスでも末尾 `\n` があれば発生する。

対策は **末尾 `\n` を置かず、ブロック下の余白は `Container` の `margin` で確保**する（単独行への隔離は先頭 `\n` が担う）。`width: double.infinity` で全幅化しても解決するが、上記のとおり iPad overflow を起こすため採らない。背の低いブロック（短い引用など）では気づかれにくいだけで同じ構造は同じ症状を持つ。添付画像も同型（#842 / follow-up #843）。

### `Image.network` には `errorBuilder` を付ける

アバター読み込み失敗時（Misskey proxy の 404 等）にバツ印のプレースホルダが出てしまう。`errorBuilder` で必ずフォールバック UI を用意する。

### テキストに流し込む画像は `height` だけ指定しない — デコード前の幅は 0 になる（#1032）

`RenderImage._sizeForConstraints` は `_image == null` のあいだ `constraints.smallest` を返す。`height` だけ渡して `width` を渡さない `Image` は、**デコードが済むまで幅 0** で置かれ、済んだ瞬間に実寸へ跳ねる。

固定サイズの箱（アバター・リアクションチップ等）なら見た目が一瞬変わるだけで済むが、**`WidgetSpan` として `Text.rich` に流し込んでいる場合は行の折り返し位置＝行数が変わり、そのタイル全体の高さが変わる**。タイムラインの `RenderSliverList` はビューポート外の高さを dead reckoning で持っているため、上へ戻って破棄済みタイルを作り直したときに実測が想定と食い違うと `SliverGeometry.scrollOffsetCorrection` が出る。補正は `pixels` を動かすので、フリングの慣性中だと**スクロール位置が跳ねる**（iOS の `BouncingScrollPhysics` だと特に派手）。

⚠ **`ImageCache` に載っているあいだは表面化しない。**既定は 1000 枚 / 100 MiB（`painting/image_cache.dart`）で、実況中は 1 画面あたりのカスタム絵文字が多く、下へ送るほど回転して一度見た画像が落ちる。「戻るときだけ起きる」「絵文字が多い TL だけ起きる」という報告の形になる。

対策は**寸法を先に知って `width` を渡す**こと。Mastodon の `/api/v1/custom_emojis` も Misskey の `/api/emojis` も寸法を返さないので、初回デコード時のアスペクト比を自前で覚える（`ui/widget/inline_custom_emoji.dart` の `EmojiAspectRatioCache`）。⚠ **`maxWidth` で cap を置く形にしてはいけない**（#858 で横長絵文字が細い帯に潰れた）。渡すのは実寸そのもので、頭打ちは従来どおり `RenderParagraph` の `maxWidth` に委ねる。

⚠ 寸法を覗くために `ImageStream` を購読したままにすると、その画像が `ImageCache` の live 扱いになって追い出されなくなる。**比が取れたら listener を外す。**

### PostTile の iPad オーバーフロー問題

`Row + Expanded` 構成は iPad の広い画面で `RenderFlex overflow` を原因不明のまま起こすことがある。`Stack + Padding(left: 52) + Positioned` で回避した（v0.3.0）。同様の問題を見たら同じ方針で。

### `go_router` の値受け渡し

`context.push<T>('/route')` + `context.pop(result)` を使う。`Navigator.pop(context, result)` では `go_router` が戻り値を握りつぶす。`showGeneralDialog` のコールバック方式もリビルドで消失するため不可。

#### `extra` は refresh のたびに消える — 画面をまたぐ引数はクエリで運ぶ（#1057）

⚠⚠ `refreshListenable` が鳴ると `RouteMatchList` が**シリアライズ経由で組み直される**。`extraCodec` を渡していないので `json.encoder.convert(extra)` に掛かり、**`BackendType`（enum）のような JSON にできない値が 1 つでも入っていると extra が丸ごと `null` に落ちる**（`RouteMatchListCodec._toPrimitives`）。⚠ **クエリパラメータは残る**ので、**画面の生存中ずっと要る引数はクエリで運ぶ**（`loginLocation()` / `resolveLoginArgs()` のように、組み立てと読み取りを 1 対で置いて両側を通す）。⚠ **refresh を跨いでも State は作り直されない**ので、クエリ化すれば画面の続行は保てる。

⚠⚠ **`push` で積んだぶんは top-level redirect の `matchedLocation` に出ない。**`RouteMatchList.push` は `copyWith(matches:)` だけで **`uri` を更新しない**。ホームから `/server` → `/login` と積んでも location は `/home` のままなので、**`matchedLocation` を見る分岐は「押し込み経路でだけ黙って成立しない」**。初回ログイン（`go('/server')`）では成立するため、**新規ユーザーでは動いて既存ユーザーで動かない**という割れ方をする。

⚠ **どちらも go_router 側の挙動なので、こちらのコードをいくら読んでも出てこない。**`~/.pub-cache/hosted/pub.dev/go_router-<版>/lib/src/` を直接読むのが早い。⚠ **この 3 点（extra が消える / State は保たれる / push は location に出ない）は `router_login_args_test` で固定してある**——前提が崩れると対策ごと無効になるため。

⚠ 同じ原理で **`state.extra!` の強制 unwrap は refresh を跨ぐと落ちうる**（[#1107](https://github.com/pooza/capsicum/issues/1107)）。

### MFM リンク記法の URL 抽出

MFM のリンク記法 `[text](URL)` は、現状の正規表現ベースの URL 抽出だと末尾の `)` が URL の一部として誤認識される。MFM パーサー実装時にこの問題も解消すること。

### 外部パッケージの enum への網羅 switch は CI 時限爆弾（dio など）

capsicum の依存は `^` 制約の浮動指定で `pubspec.lock` も `.gitignore` 対象のため、CI は毎回最新版を解決する。外部パッケージが enum に値を足すと、`default:` の無い網羅 switch が `non_exhaustive_switch_statement` でコンパイル不能になり、**ソース無変更のまま CI が突然全滅する**（手元は旧 lock を握っていて再現しない）。v1.42 で dio 5.10.0 の `DioExceptionType.transformTimeout` 追加により `push_relay_client.dart` の網羅 switch が落ち、develop の Analyze / Linux / Windows Release が全滅した。**外部パッケージの enum を switch するときは必ず `default:` を置く**（前方互換）。ローカル analyze が通っても CI と dio 解決バージョンがズレている可能性があるので、CI 失敗時はまず `dart pub upgrade <pkg>` で最新解決に揃えて再現確認する。

### Android 16KB ページサイズ：irondash の precompiled `.so` が 4KB で Play に弾かれる

Google Play は 64bit `.so` の LOAD セグメントが 16KB 整列（`p_align >= 16384`）でないと製品版昇格を `Artifact does not support 16KB page size` で拒否する（2026-06 にハード強制が有効化。それ以前は警告で、同じ 4KB バイナリのまま production に出ていた＝我々の回帰ではなくストア側の締め付け）。v1.42 build 138 で踏んだ。

原因は `irondash_engine_context`（`super_drag_and_drop` → `super_native_extensions` の transitive 依存）。cargokit はデフォルトで **GitHub の precompiled `.so` をダウンロード**して使い、irondash 0.5.5（最新）の precompiled が 4KB 整列・upstream 修正なし（姉妹 super_native_extensions は build.rs に `cargo:rustc-link-arg=-Wl,-z,max-page-size=16384` があり precompiled も 16KB 済み）。**ELF セグメント整列は後から変えられない**ので zipalign 等では直らない。

対処（恒久・コミット済み）: `packages/capsicum/android/cargokit_options.yaml` に `use_precompiled_binaries: false` を置いてローカル Rust ビルドへ切り替え（要 rustup + android ターゲット）、ビルド時に `CARGO_ENCODED_RUSTFLAGS=-Clink-arg=-Wl,-z,max-page-size=16384` を渡して 16KB 整列させる。**stale な gradle daemon は古い環境を握っていてフラグを取りこぼす**ので `./gradlew --stop` してから build。手順・検証の正本は `.claude/skills/store-release/build-upload.md` §4.2「Android: 16KB ページサイズ対応」。アップロード前に `.so` の `p_align` を必ず検証する。

### 仕様に迷ったらまず本家 Mastodon / Misskey の実装を確認する

ストリーミング・ページネーション・通知など、SNS の挙動に関わる設計判断で迷ったら、推測する前に本家 WebUI の実装を読む癖をつける。手元のフォーク（`~/repos/mastodon` = bshockdon / `~/repos/misskey` = daisskey）に上流コードが入っており、`git fetch` で最新化して確認できる（[server-forks の経緯はメモリ参照]）。capsicum の方が手厚いこともあれば、本家の方が枯れていて正しいこともあるので、まず一次情報を当たる。

実例（ストリーミング再接続、v1.42 #786 調査）: 切断・再接続は不具合ではなく標準的な機構で、本家 WebUI も自動再接続ライブラリを噛ませている。

- **Mastodon**: `@gamestdio/websocket`（指数バックオフ付き自動再接続）。再接続後のギャップは埋めず、TL 先頭に `TIMELINE_GAP`（手動「もっと見る」）を挿すだけ（[reducers/timelines.js の `reconnectTimeline`]）。
- **Misskey**: `reconnecting-websocket`（バックオフ付き自動再接続、misskey-js `streaming.ts`）。再接続時はチャンネルを張り直すのみで、切断中のギャップを能動回収はしない（realtime は prepend 任せ・非 realtime は `fetchNewer` ポーリング）。
- **capsicum**: live 復帰時に since までさかのぼって REST 差分を能動回収（`collectCatchUpGap`）。取りこぼし対策はむしろ両本家より手厚い。#784/#782 の方向性が正しかったことの裏取りにもなった。

### `WebSocketChannel.connect` には liveness が無い — 無音切断検知には `pingInterval` 必須（#788）

`web_socket_channel` の `WebSocketChannel.connect(uri)` を引数なしで張ると ping/pong を一切送らない。無音切断（NAT/プロキシのアイドル切断・モバイル回線・サーバーの ungraceful な離脱）では TCP に FIN/RST が来ず、`onDone`/`onError` が発火しないため、capsicum は「繋がっているつもり」で死んだソケットに座り続け **再接続トリガー自体が引かれない**。バックオフをいくら粘らせても、検知が無ければ復帰しない（#784/#782 は「検知後」の層なので無音切断には効かない）。

対処は `IOWebSocketChannel.connect(uri, pingInterval: ...)`。dart:io が `pingInterval` ごとに WS ping を送り、同間隔内に pong が無ければ自動で close → `onDone` 発火 → 既存の再接続ロジックが動く。検知時間 ≒ `pingInterval`。本家 Misskey WebUI が「頻繁に再接続している」のはこの検知が効いて素早く復帰しているからで、頻度の高さは弱点ではない。capsicum は timeline=30s / notification・chat=60s で設定（Mastodon/Misskey 両プロトコル共通の欠落だったため両方に入れた）。`pingInterval` は dart:io 由来で web では使えないが、capsicum は web を出荷対象にしていないため `IOWebSocketChannel` 直叩きで問題ない。md.korako.me（Mastodon）と きゅあすきー（Misskey）の両方で「再接続できない」が同時報告されたのが発見の端緒（karasu_sue 報告）。

### Riverpod の `ref.onDispose` は「破棄」だけでなく「再計算のたび」にも走る（#890）

`build()` 内で `ref.onDispose(() => _disposed = true)` のような破棄フラグを立てると、**依存 provider の変化による再計算でも発火する**ため、フラグが一度立ったきり戻らない。build 後も動き続ける非同期処理（キャッシュ先出しの裏で走る初回取得など）がそのフラグを見ていると、以降のすべての `state` 更新が黙って捨てられる。

対処は 2 つ併用する:

- `build()` の先頭でフラグを `false` に戻す（Notifier のインスタンスは再計算をまたいで生き残るため、リセットしないと戻らない）
- 「古い build の非同期処理が新しい state を上書きしない」ことは、フラグではなく **世代カウンタ**（`final generation = ++_buildGeneration;` を build 冒頭で採り、書き戻し時に `generation != _buildGeneration` なら捨てる）で担保する

### 「その端末だけの値」を SharedPreferences に置かない — OS バックアップで別筐体へ複製される（#952）

SharedPreferences は **Android / iOS とも OS のバックアップ対象**で、機種変・復元で**別の物理デバイスへ丸ごと複製される**。Android は Auto Backup が既定 ON で `shared_prefs/` を含み（`android:allowBackup="false"` も `dataExtractionRules` も置いていない場合）、iOS は NSUserDefaults（`Library/Preferences/*.plist`）が iCloud / 暗号化バックアップに入る。アンインストール → 再インストールでも復元されうるので、「アンインストールで消える」も前提にできない。

したがって **「この端末を他の端末と区別する値」を SharedPreferences に置くと、復元した端末と元の端末が同じ値を名乗る**。capsicum ではプッシュ購読の dedup キー（`DeviceInstallId`）がこれを踏み、サーバー側が `UNIQUE(account, server, device_id)` の upsert に切り替わると**どちらか一方の端末に push が届かなくなる**設計欠陥になっていた。

寿命で選ぶなら `flutter_secure_storage`（機密性ではなく**バックアップに乗らない**のが採用理由）:

- **iOS / macOS**: `KeychainAccessibility.first_unlock_this_device`（`…ThisDeviceOnly`）。ThisDeviceOnly の item はバックアップに含まれないため復元先には存在せず、その端末で作り直される。`_this_device` の付かない `first_unlock` / `unlocked` はバックアップに乗るので**この用途では選べない**。
- **Android**: EncryptedSharedPreferences のマスター鍵が Android Keystore にあり、鍵はバックアップされない。復元先では既存エントリを復号できず read が失敗するので、**その場で作り直す実装にしておく**（例外を握り潰して同じ値を返し続けてはいけない）。
- **desktop**: Windows は DPAPI（ユーザー + マシン束縛）、Linux は libsecret。プロファイルのコピーでは復号できない。

保存先を移すときは**旧値を移行しない**。移行すると複製された値がそのまま生き残り、直したい事象が消えない。旧キーは掃除だけする。正本は [`device_install_id.dart`](../packages/capsicum/lib/src/service/device_install_id.dart)。

### 画像を扱う UI のテストは `tester.runAsync` が要る — 無いと**黙ってハングする**（#947）

`flutter_test` の既定は擬似非同期で、**画像コーデックのような実 I/O を進めない**。そのため `ui.instantiateImageCodec` / `Picture.toImage` / `Image.toByteData` を待つコードは、テスト内で呼ぶと**エラーも出さずに止まる**。「テストが黙ってタイムアウトする」ときは真っ先にここを疑う。

- **`tester.runAsync(() async { ... })` の中でだけ実 I/O が進む。** ここを通せば `PictureRecorder` → `toImage` → PNG エンコード → デコード → ピクセル取り出しまで一通り動く（実測 2026-08-13）。**合成結果をピクセル単位で検証できる**ので、この層に integration_test は要らない。
- **順序が効く。** 「操作 → `pump`（route 構築・`initState` の開始）→ `pump(遷移ぶん)` → `runAsync`（実 I/O）→ `pump` ×2（完了した Future の続きを反映）」。先に `runAsync` すると、まだ何も始まっていない時間だけ進めることになり画面が出てこない。
- **`pumpAndSettle` は使えない。** デコード中は `CircularProgressIndicator` が回り続けるので必ずタイムアウトする。
- **素材は `setUpAll` で作る。** `testWidgets` の本体は擬似非同期なので、その中で `toImage` を呼ぶとハングする。`ui.Image` を使い回すときは、画面側が dispose するので `clone()` を渡す。
- 書き出し結果を受け取るまでには「実 I/O → `pop` → 遷移アニメーション → 呼び出し元の `push` future 解決」と段があり、1 回 `settle` しただけでは届かない。実時間と擬似時間を交互に進める。

土台は [`test/support/image_editor_harness.dart`](../packages/capsicum/test/support/image_editor_harness.dart) に閉じ込めてあるので、利用側はこの作法を意識しなくてよい。ネットワークとアカウントを要求する経路（スタンプ素材の調達）は [`StickerSource`](../packages/capsicum/lib/src/service/sticker_source.dart) を override して切り離す。

**ダイアログの `TextEditingController` は呼び出し側で dispose しない。** `showDialog` の future は `Navigator.pop` の時点で解決するが、そこはまだ**退場アニメーションの最中**で、`TextField` は再構築される。解決直後に dispose すると use-after-dispose の assertion になる（debug で落ち、release では黙って通る）。controller はダイアログ本体を `StatefulWidget` にして**そちらに所有させる**（State の dispose はルートが実際に外れてから呼ばれるので、リークもせず早すぎもしない）。

### アクション付きの `SnackBar` は既定で**閉じない** — `duration` が効かない（#1126）

`SnackBar` の `persist` は `persist ?? action != null` で解決される。つまり **`SnackBarAction` を付けた瞬間に「時間で消えない」が既定**になり、`duration` に何を書いても無視される（`ScaffoldMessenger` のタイマーは `snackBar.persist` なら何もせず戻る）。

- **「元に戻す」系は `persist: false` を明示する。** さもないと利用者が触るまで画面の下に居座り、**その SnackBar が閉じるのを待って解放する資源があると、上限が消える**。#1126 の削除の取り消しは、取り消し待ちのスタンプの `ui.Image`（原寸・ネイティブ側）を SnackBar が閉じるまで掴む設計なので、ここを外すと画面を閉じるまで解放されない。
- **ウィジェットテストでは「SnackBar が自分で閉じること」まで見る。** 閉じないと `ScaffoldFeatureController.closed` が解決せず、解放も走らない。`expect(find.text('元に戻す'), findsNothing)` を期限経過後に置くのが歯になる。
- ⚠ **期限切れを待つには `pump` を 2 段に分ける。** 表示時間のタイマーは**登場アニメーションが完了した後の build** で仕掛けられるので、`pump(duration)` を 1 回打っても閉じない。`pump()` → `pumpAndSettle()`（登場を終わらせる）→ `pump(duration + α)`（タイマーを発火）→ `pumpAndSettle()`（退場）の順で進める。タイマーが走っている間はフレームが積まれないため、`pumpAndSettle` だけでは**待ったつもりで待てていない**。

### レイヤの不透明度は「色の alpha」ではなく `saveLayer` で掛ける。⚠ **bounds は渡さない**（#1128）

重なりを持つレイヤ（capsicum の文字レイヤは白い本体 + 黒い擬似アウトライン 4 枚）に色ごとの alpha を掛けると、**重なった画素だけ二重に合成されて濃く出る**。プレビューの `Opacity` は「1 枚に描いてから alpha を掛ける」ので、書き出し側も `canvas.saveLayer` で囲って同じ意味にしないと WYSIWYG が割れる。換算は `ui.Color.getAlphaFromOpacity`（`Opacity` が内部で使うのと同じ式）。

⚠⚠ **`saveLayer` の第 1 引数に矩形を渡すと、レイヤの縁で描画が削られる。** `Rect.fromLTWH(0, 0, w, h)`（画像全体）を渡しただけで、**文字の擬似アウトラインの外側 1 列 / 1 行が丸ごと落ちた**（`Shadow` は `blurRadius: 0` でも `convertRadiusToSigma(0) = 0.5` のぼかしが掛かる。2026-09-23 実測で、**被覆 42% の行まで消えた**）。文字は画像の中央にあり矩形には十分収まっているので、「はみ出したから切れた」ではない。**`null` を渡してエンジンに決めさせると起きない。**

- **完全に不透明なときはレイヤを挟まない**（`alpha != 255` のときだけ囲う）。挟むだけで上の欠けが起きるので、**既存の書き出しを 1px も変えないために必要**であって、最適化ではない。
- **検査は「全画素で `o% の書き出し = o × 不透明の書き出し + (1-o) × 元画像` が成り立つ」で書く。** 1 画素の色を見るだけだと「たまたまそこだけ合っている」を排除できず、**上の縁の欠けも見逃す**（実際、この全画素検査だけが bounds の問題を捕まえた）。⚠ 回転を使わなければ中間色はグリフの縁だけなので、許容差 2 で通る。

### 「できる / できない」の判定は 1 本にして、ボタンの活殺と実処理の両方から呼ぶ（#1127）

`onPressed: locked ? null : _doIt` のようにボタン側だけで止めると、**`_doIt` の中のガードは一度も呼ばれない**。そのガードを消してもテストは緑のままで、**導線が 1 つ増えた瞬間に黙って通る**。逆に実処理側だけに置くと、押せる見た目のまま無反応になり「壊れている」と読まれる。

- **述語を 1 つ定義し（例 `bool _canModify(item)`）、ボタンの活殺と実処理の入口の両方がそれを見る。** こうすると述語を骨抜きにしたときに **UI の検査が落ちる**ので、判定そのものに歯が立つ。
- ⚠ **穴を開けて確かめるときは、述語だけでなく「1 つの導線だけ判定を外す」穴も開ける。** 導線ごとに別々の判定を書いていると、片方を壊しても緑になる。
- これは「[ソース検査ガードの書き方](CLAUDE.md#ソース検査ガードの書き方)」と同じ型の failure —— **検査（ここでは実行時のガード）が動いていないのに緑**。

### `ReorderableListView` は `onReorderItem` を使う — 旧 `onReorder` と `newIndex` の流儀が違う

`onReorder` は非推奨で、`newIndex` を**取り除く前**の位置で渡す（後ろへ動かすとき `-1` の補正が要る）。後継の `onReorderItem` は Flutter 側が `if (newIndex > oldIndex) newIndex -= 1;` を済ませてから呼ぶので、**受け取った値をそのまま `insert` する**。

補正を二重に掛けると「後ろへドラッグしても動かない / 1 つ手前に落ちる」になり、**前へ動かす操作では正しく動く**ぶん見つけにくい。実装は `tab_management_sheet.dart` の `_reorderEntries`（#836）と `reorderOverlayLayers`（#1126）が正本。

### 書き出し画像の**全画素ハッシュはプラットフォームを跨げない**（#1125 / #1126）

`Canvas` 合成の結果を FNV ハッシュで固定する検査は、**軸に平行な描画なら完全に決定的**（実測: 回転なしの書き出しは中間色 0 画素）だが、**レイヤを回した瞬間に縁へアンチエイリアスが乗り**（30° で 239 画素）、その被覆率が macOS と Linux で一致しない。同じコード・同じ Flutter でも指紋が変わる。

- **回転・拡大縮小が絡む検査に指紋を使わない。** 軸に平行で整数の矩形になる場面（スタンプだけ等）に限れば中間色が 0 画素になり、**全プラットフォームで同じ値**になる。そのうえで**「中間色が 0 画素であること自体」も検査する** —— そうしないと、後からその場面に回転や文字を足したときに、固定値が静かに環境依存へ変わる。
- ⚠⚠ **固定値の場面を「画面を操作して」作らない。**操作で作ると**編集画面のレイアウトに依存する**。#1128 でツールバーに行を 1 本足しただけでキャンバスが 756px → 708px に縮み、テスト中の「ドラッグで端へ寄せる」が別の位置に着地して、**描画を何も変えていないのに CI が落ちた**（実測: スタンプの中心が ny 0.229 → 0.212）。場面は**座標と大きさを直接与えて**組む（capsicum では #1129 の `initialLayers`）。
- **「編集画面の大きさを変えても書き出しは 1px も変わらない」を検査に入れる。**書き出しは原寸の Canvas に対して行うので本来レイアウトに依存しない。依存していたら、ツールバーに行を足すだけで投稿される画が変わることになる。
- **移植可能な歯は構造で取る。** 「どのレイヤに操作が当たったか」はウィジェットツリー（`Transform` の回転行列など）から直接読める。ラスタライザに依存しないので全 OS で走る。
- 画素で見たいときは**軸に平行なまま**にして、「同じ座標に 2 枚重ねて出てきた色」のような 1 画素の判定に落とす。

### ソース検査ガードで「名前の最初の出現」から本体を切り出さない（#1130）

`_bodyAfter(masked, RegExp('$name\\s*\\('))` のように**名前で最初に当たった `{`** から本体を取る書き方は、**呼び出しのほうが宣言より先に現れるメソッドで別の本体を掴む**。#1130 で `_saveDraft` を見ようとして、`didChangeAppLifecycleState` の中の `_saveDraft();` に当たり、**ライフサイクル側の本体を検査していた**（`_addOverlay` はたまたま宣言が先だったので、同じヘルパーが今まで正しく動いていた）。

⚠⚠ **失敗の出方が紛らわしい。**本体は切り出せている（null にならない）ので「切り出せていることの検査」は通り、**中身が違うだけ**なので「目印が無い」という一見もっともらしい赤になる。判定が壊れているのか実装が規約違反なのかを取り違える。

- **宣言だけに当てる。**戻り値の型が前に付いていることを求める（`RegExp('\\w[\\w<>?, ]*\\s+$name\\s*\\(')`）。呼び出しは `;` / `(` / `)` / 行頭の空白が前に来るので当たらない。
- ⚠ **本体を掴んだことの目印は「そのメソッドにしか無いもの」にする。**両方の候補に在る文字列を目印にすると、入れ違ったまま緑になる。

## 体感速度の改善（先出し・キャッシュ）

### 先出しキャッシュは「同じ状態への経路」を 2 本にする — 欠陥はほぼ全部その分岐から出る

v1.53 の #890（ホーム TL の起動時キャッシュ）で、リリース前レビューの指摘の**おおよそ半分**がこの機能 1 つに集中した。個別のバグは別々に見えたが、型は 1 つだった: **キャッシュ経路と通常経路で振る舞いが違う**。

実際に出たもの:

- **エラーの扱いが違う** — 通常経路は `build()` の戻り値が Riverpod に `AsyncError` へ変換されるが、キャッシュ先出しは `unawaited` で走らせるので失敗が握り潰され、古い一覧が出たままになった（🔴）
- **前値の有無が違う** — キャッシュ経路は `AsyncError` に前値が残るので stale 判定を抜けてエラー画面に到達するが、通常経路は前値が無いのでスピナーに潰された。**キャッシュがある方がエラー処理が強い**という逆転（🔴）
- **計測が載る側が違う** — キャッシュが定常化すると `fetch_ms` を持つコホートが「キャッシュを使えなかった起動」だけに縮み、REST が遅くなっても速く見える
- **消去の対象が違う** — メモリ上の一覧・未表示バッファは掃除したのに、ディスクのキャッシュだけブロック前のスナップショットが残った
- **書き込み順序** — `unawaited` の保存とログアウトの `clear()` が競合し、消した後に書き戻りうる（直列化キューで解決）

**教訓**: 体感速度のために状態の供給源を増やすときは、機能追加ではなく**状態機械の分岐追加**として設計・レビューする。最低限、以下を経路ごとに突き合わせる。

1. 失敗したとき何が見えるか（エラー文・再試行導線の有無）
2. 前値・世代・文脈キーのガードが両方に効くか
3. 計測がどちらの経路で載るか（母数が偏らないか）
4. 消去・無効化がすべての供給源に届くか（メモリ / 未表示バッファ / ディスク）
5. 非同期の書き込み順序が確定しているか

なお **6 巡のレビューでも「オフライン起動では router が `/server` へ飛ばすのでタイムライン画面に到達しない」ことは分からず、実機確認で初めて出た**（→ #917）。経路の存在自体を取り違えていると、静的レビューは何巡しても気付けない。

## 観測（Sentry）

### `level=fatal` / `handled=no` はプロセス死を意味しない（#901）

sentry_flutter の `OnErrorIntegration` は、**`PlatformDispatcher.onError` に届いた例外へ一律に `SentryLevel.fatal` をハードコードする**（SDK 9.27.0 の `lib/src/integrations/on_error_integration.dart` で実測）。`handled` も「事前に設定されていた `onError` が `true` を返したか」でしかなく、アプリが落ちたかどうかとは無関係。SDK 自身のコメントも "the app **might** crash on some platforms after this is called" と書いている。

Android では**非同期の未捕捉 Dart エラーでプロセスは落ちない**。したがって Sentry で `fatal` と出ているイベントの多くは「クラッシュ」ではなく、**どこかで処理が途中で飛んだだけ**である。

これを取り違えると観測 issue が実害と接続できなくなる。#901 が実例で、起票時の本文に「fatal / **未捕捉クラッシュ**として再発している」と書いたため:

- 実際に起きていたのは **タイムラインの無限スクロールが止まる**（再起動で復帰）という症状だった
- pooza は突然終了を経験していないので「クラッシュの心当たりが無い」となり、**同じ現象なのに 3 週間以上ひも付かなかった**
- pooza 側はその間ずっと**サーバー起因**を疑っていた

**教訓**: 観測 issue には Sentry の文言をそのまま写さず、**「この例外が起きたとき、ユーザーには何が見えるか」を書く。**書けないなら、そこがまだ分かっていない部分として明示する。スタックが framework 内部で終わっていても、症状の予想は立てられる（例: `FutureHandlerProviderElementMixin.onData` での `Future already completed` は、**1 回目の完了は成功しているので値は届いており、2 回目の配信が落ちて UI が更新されない**と読める）。

同じ取り違えは #89（「無限スクロールが数回で停止する」を WebSocket の未ハンドル例外 125 回から追った回）でも起きている。**「TL が更新されない」系の報告は、サーバー側を疑う前に Sentry の未捕捉 async エラーと突き合わせる。**

## デスクトップ（drag & drop / ネイティブ連携）

### drag-out の重い処理（ダウンロード等）は `dragItemProvider` ではなく virtual file provider に置く

super_drag_and_drop で virtual file を使ってメディアを drag-out する際（#645 メディアビューア画像保存）、ネットワーク取得などの `await` を**ドラッグ開始時の `dragItemProvider`（async）に置くと Windows でドラッグが「できたりできなかったり」**になる。Windows の OLE ドラッグ（`DoDragDrop`）はジェスチャー内で同期的に開始する必要があり、開始前に await が挟まると取得完了までドラッグが始まらず、回線・タイミング次第で起動が間欠的に失敗する。macOS は item provider から後追いでドラッグセッションを開始できるため同じコードでも顕在化せず、プラットフォーム差で気付きにくい。

対策: 取得は `addVirtualFile` の **provider（drop 時に呼ばれる）内で遅延実行**し、`dragItemProvider` は await せず同期で `DragItem` を返す。`addVirtualFile` はそもそも「DL 等で時間がかかる on-demand 生成」を想定した API（パッケージ doc 参照）であり、これが本来の使い方。Dart 共通コードなので macOS も同挙動になる（virtual file の遅延 async は D&D で公式サポート・回帰なし）。差が出るのは低速回線時のみ。実装は [media_viewer_screen.dart](../packages/capsicum/lib/src/ui/screen/media_viewer_screen.dart) の `_DragOutImage`。

### desktop のドラッグ操作はマウス＝即ドラッグ・タッチ＝長押し→持ち上げ

super_drag_and_drop の drag 開始ジェスチャーは入力デバイスで異なる。マウスは長押し不要の即ドラッグ、タッチは長押し→そのまま持ち上げ（スクロール/タップとの誤認回避・iOS/Android と同方式）。タッチ環境で「長押しが要るのか即ドラッグなのか」分かりにくいが仕様。drag-out が動かないという報告は、まずコードでなくこの操作差を疑う。

## 認証フロー

### `flutter_web_auth_2` が Android エミュレータで不安定

`CallbackActivity` 方式でカスタムスキーム (`capsicum://oauth`) を受けるが、Android エミュレータで安定して動作しない。`url_launcher` + OOB（手動コード入力）フォールバックで代替している（[login-troubleshooting.md](login-troubleshooting.md) も参照）。

### Android の凍結（App Freezer）を実機で追う道具（#1108）

Android 12+ は背面に回ったプロセスを**凍結**する。OAuth のように「ブラウザを操作しているあいだ capsicum が待つ」形は正面からこれに当たり、**loopback の callback ページを返せない**＝承認しても戻らない。⚠ **検証を人の目視に頼らない**——下はすべて adb で読める。

- `adb logcat -G 16M` を**検証開始前に**（`-G` はバッファを消す）。⚠ **ストリームは USB 切断で落ちる**ので `-d` で吸い出す方式にする
- 凍結: `adb logcat -d | grep "freezing <pid>"` / 解凍は `sync unfroze`
- キャッシュ状態: `adb shell cat /proc/<pid>/oom_score_adj` が 900 台。⚠ **切り替え直後は 700 だが、放置すればそのまま落ちる**
- コールバック到達: `adb shell cat /proc/net/tcp | grep -i 1BBB`（7099）。5 番目のフィールドが `tx:rx` で、**rx が 0 以外なら未読が積まれている**＝届いているのに読めていない
- 通知が出たか: `adb shell dumpsys notification`。⚠ **チャンネルの `mLastNotificationUpdateTimeMs` は通知が消えた後も「いつ投稿されたか」を残す**ので、「出なかった」を事後に反証できる。⚠ **Android 12+ は foreground service の通知を約 10 秒遅らせる**ので、出した直後にシェードを見ても無い
- ⚠ **アプリを 4 つ開くと LMK に capsicum ごと殺される。**押し下げは**放置だけで足りる**

### デバッグ APK の手動インストール

`flutter build apk --debug` → `adb install` で実機・エミュレータにデバッグ APK を直接導入可能。Flutter の run 経由だと起動できない状況（署名・権限問題等）の切り分けに使える。

### `flutter_secure_storage` の accessibility 変更は既存 Keychain item を取りこぼす

macOS / iOS 実装は `baseQuery` に **必ず `kSecAttrAccessible` を含める**（`read` / `readAll` / `containsKey` / `delete` すべて）。そのため `MacOsOptions` / `IOSOptions(accessibility: ...)` を後から変更すると、**旧 accessibility で書かれた既存 item が新設定からは見えず・消せず・更新できない**。具体的な壊れ方（#643、内部ベータ実機で実証）:

- `write`: `containsKey(新)` が旧 item を検出できず `SecItemAdd` に進み、同一 account/service が既存のため **-25299 (errSecDuplicateItem)**。ログイン成功直後の `saveAccount` で発火して「ログインに失敗しました」になる。
- `delete(新)`: 旧 item にマッチせず no-op。単純な delete+retry でも直らない。
- `readAll(新)`: 旧 item を返さないため、read → delete → re-write 型の migration が**空振り**し、flag だけ立って「移行済み」を詐称する。

対処: 旧 item を列挙・削除する際は **旧 accessibility を per-call options で明示**する（#643 以前の既定は `KeychainAccessibility.unlocked` = `WhenUnlocked`）。migration の `readAll` / `delete` と write リカバリの delete に旧 options を渡し、空振りしていた migration を全員に再実行させるため flag key も `_v2` 等に上げる。`PushKeyStore.migrateAccessibilityIfNeeded`（#392 / #656）も同型実装。なお debug（macOS は sandbox off）では再現せず、内部ベータ実機 + Sentry breadcrumb でしか追えない。

派生注意: 移行で旧 item が「読めるようになる」と、そこに残っていた **stale な値が再利用される**副作用がある。capsicum では古い `client_creds`（`capsicum://oauth` era 登録）が localhost redirect_uri で `invalid_redirect_uri` を招いた。client_creds に redirect_uri を併記し一致時のみ再利用する形で解消。

### Linux の secure storage は読み取り失敗を分類できない — 失敗で secret を消してはいけない（#1104）

`flutter_secure_storage_linux` は **read / write / readAll / delete / deleteAll / containsKey の全失敗を `PlatformException(code: "Libsecret error")` 1 種類に潰す**（`linux/flutter_secure_storage_linux_plugin.cc` の `catch (const gchar *e)`）。⚠ **Apple の `errSecInteractionNotAllowed` (-25308) のような「transient を名指しするコード」が存在しない**ので、`_isKeychainTransient` 相当の分岐を Linux 向けに書き足す道は最初から無い。

さらに `linux/include/Secret.hpp` の `readFromKeyring()` は、**読み取りのたびに `warmupKeyring()` を呼ぶ**。中身は `FlutterSecureStorage Control` という**別 item への dummy 書き込み**で（crbug.com/660005 の回避策）、失敗するとリテラル `throw "Failed to unlock the keyring"` になる。

⚠⚠ **ここから「secret は無傷」が構造的に保証される。**warmup はユーザーの item を読みも消しもしていないので、この例外が飛んだ時点で**保存済みの値は損なわれていない**。プラグイン自身のコメントも「**ユーザーが解錠プロンプトをキャンセルしたのか区別できない**」と明記しており、**解錠のキャンセル 1 回**でも同じ例外になる。

したがって **Linux では読み取り失敗を理由に `delete` してはいけない**。誤りのコストが対称でないのが決め手で、permanent を消し損ねても**再ログインが secret を上書きするので無害**だが、transient を permanent と誤判定すると**その場でアカウントが消える**（`restoreSessions` は保存済みアカウントを順に回すので**全件が対象**）。同じ理由で Android（Keystore）も以前から除外されていた（#730 / #731）ので、判断の軸を「プラットフォーム」ではなく **読み取り失敗から permanent を判別できるか**（`mayDeleteSecretOnReadFailure`・Apple のみ true）に置いた。Windows（DPAPI）も同じ穴なので一緒に塞がる。

⚠ **delete は 2 箇所ある**（`getSecrets` の `on PlatformException` 側と `catch` 側）。`BadPaddingException` のように `PlatformException` でラップされずに来る経路があるため、**片方だけでは塞がらない**。

⚠ **「応答が返らない」（#1085）と「例外で断る」（#1104）は別の壊れ方。**前者は `kill -STOP` で作れてタイムアウトで受け、後者はサービスに到達できない / 解錠が成立しないときに出る。**どちらか一方の対処では塞がらない。**

#### 隔離して実機検証する型（本物のキーリングに触れない）

⚠ **LXC は不要。**隔離が要る軸は 2 つだけで、`dbus-run-session`（私設セッションバス＝`org.freedesktop.secrets` の接続先）と `XDG_DATA_HOME` の差し替え（キーリングの実体ファイル）で足りる。⚠ **`XDG_RUNTIME_DIR` も差し替える** — さもないと `discover_other_daemon` が `/run/user/<uid>/keyring` の**本物を見つけて起動を譲る**。⚠ **D-Bus activation の前に `gnome-keyring-daemon --unlock --components=secrets` でキーリングを作っておく**（無いと解錠プロンプト待ちで固まる）。⚠ **`kill -STOP` の対象 PID には安全弁を付ける**（本物の PID / `control-directory=/run/user/<uid>` を弾く。実際に PID 取得に失敗して `/sbin/init` を指した）。

## ネイティブプッシュ / CI・ビルド

⚠ **別ファイルにある → [tech-notes-native.md](tech-notes-native.md)。**macOS ネイティブ APNs 配線の 3 つの罠 / Windows WNS の AppContainer と DPAPI 境界 / プッシュ重複は上流の孤児購読を先に疑う / `set -o pipefail` と早期終了するパイプ / 大きな入力を環境変数で渡すと Linux でだけ落ちる / Windows ネイティブを触ったときの検証手順 / `.ps1` に日本語を書くと無音で構文エラー。

## サーバー API（NodeInfo / Mastodon / Misskey / モロヘイヤ）

⚠ **別ファイルにある → [tech-notes-api.md](tech-notes-api.md)。**メディア ALT の 2 ステップ送信と編集の導線条件 / `GET /api/v2/notifications` の 4 つの罠 / Misskey は推測で語らずフォークのソースを引く / `sinceId` 単独指定は ASC で返る / `/api/sw/register` はサードパーティから叩けない / Play（スロット系）の 3 つの現象 / モロヘイヤの機能フラグは `.config.features` 配下。
