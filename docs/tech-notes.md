# 技術的知見・落とし穴集

実装中に発見した Flutter / Dart / 各種 API の落とし穴と回避策。コードコメントに残すほどではないが、失うと同じ地雷を踏む知見を集約する。

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

### PostTile の iPad オーバーフロー問題

`Row + Expanded` 構成は iPad の広い画面で `RenderFlex overflow` を原因不明のまま起こすことがある。`Stack + Padding(left: 52) + Positioned` で回避した（v0.3.0）。同様の問題を見たら同じ方針で。

### `go_router` の値受け渡し

`context.push<T>('/route')` + `context.pop(result)` を使う。`Navigator.pop(context, result)` では `go_router` が戻り値を握りつぶす。`showGeneralDialog` のコールバック方式もリビルドで消失するため不可。

### MFM リンク記法の URL 抽出

MFM のリンク記法 `[text](URL)` は、現状の正規表現ベースの URL 抽出だと末尾の `)` が URL の一部として誤認識される。MFM パーサー実装時にこの問題も解消すること。

### 外部パッケージの enum への網羅 switch は CI 時限爆弾（dio など）

capsicum の依存は `^` 制約の浮動指定で `pubspec.lock` も `.gitignore` 対象のため、CI は毎回最新版を解決する。外部パッケージが enum に値を足すと、`default:` の無い網羅 switch が `non_exhaustive_switch_statement` でコンパイル不能になり、**ソース無変更のまま CI が突然全滅する**（手元は旧 lock を握っていて再現しない）。v1.42 で dio 5.10.0 の `DioExceptionType.transformTimeout` 追加により `push_relay_client.dart` の網羅 switch が落ち、develop の Analyze / Linux / Windows Release が全滅した。**外部パッケージの enum を switch するときは必ず `default:` を置く**（前方互換）。ローカル analyze が通っても CI と dio 解決バージョンがズレている可能性があるので、CI 失敗時はまず `dart pub upgrade <pkg>` で最新解決に揃えて再現確認する。

### Android 16KB ページサイズ：irondash の precompiled `.so` が 4KB で Play に弾かれる

Google Play は 64bit `.so` の LOAD セグメントが 16KB 整列（`p_align >= 16384`）でないと製品版昇格を `Artifact does not support 16KB page size` で拒否する（2026-06 にハード強制が有効化。それ以前は警告で、同じ 4KB バイナリのまま production に出ていた＝我々の回帰ではなくストア側の締め付け）。v1.42 build 138 で踏んだ。

原因は `irondash_engine_context`（`super_drag_and_drop` → `super_native_extensions` の transitive 依存）。cargokit はデフォルトで **GitHub の precompiled `.so` をダウンロード**して使い、irondash 0.5.5（最新）の precompiled が 4KB 整列・upstream 修正なし（姉妹 super_native_extensions は build.rs に `cargo:rustc-link-arg=-Wl,-z,max-page-size=16384` があり precompiled も 16KB 済み）。**ELF セグメント整列は後から変えられない**ので zipalign 等では直らない。

対処（恒久・コミット済み）: `packages/capsicum/android/cargokit_options.yaml` に `use_precompiled_binaries: false` を置いてローカル Rust ビルドへ切り替え（要 rustup + android ターゲット）、ビルド時に `CARGO_ENCODED_RUSTFLAGS=-Clink-arg=-Wl,-z,max-page-size=16384` を渡して 16KB 整列させる。**stale な gradle daemon は古い環境を握っていてフラグを取りこぼす**ので `./gradlew --stop` してから build。手順・検証の正本は docs/store-release-guide.md §4.2「Android: 16KB ページサイズ対応」。アップロード前に `.so` の `p_align` を必ず検証する。

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

### デバッグ APK の手動インストール

`flutter build apk --debug` → `adb install` で実機・エミュレータにデバッグ APK を直接導入可能。Flutter の run 経由だと起動できない状況（署名・権限問題等）の切り分けに使える。

### `flutter_secure_storage` の accessibility 変更は既存 Keychain item を取りこぼす

macOS / iOS 実装は `baseQuery` に **必ず `kSecAttrAccessible` を含める**（`read` / `readAll` / `containsKey` / `delete` すべて）。そのため `MacOsOptions` / `IOSOptions(accessibility: ...)` を後から変更すると、**旧 accessibility で書かれた既存 item が新設定からは見えず・消せず・更新できない**。具体的な壊れ方（#643、内部ベータ実機で実証）:

- `write`: `containsKey(新)` が旧 item を検出できず `SecItemAdd` に進み、同一 account/service が既存のため **-25299 (errSecDuplicateItem)**。ログイン成功直後の `saveAccount` で発火して「ログインに失敗しました」になる。
- `delete(新)`: 旧 item にマッチせず no-op。単純な delete+retry でも直らない。
- `readAll(新)`: 旧 item を返さないため、read → delete → re-write 型の migration が**空振り**し、flag だけ立って「移行済み」を詐称する。

対処: 旧 item を列挙・削除する際は **旧 accessibility を per-call options で明示**する（#643 以前の既定は `KeychainAccessibility.unlocked` = `WhenUnlocked`）。migration の `readAll` / `delete` と write リカバリの delete に旧 options を渡し、空振りしていた migration を全員に再実行させるため flag key も `_v2` 等に上げる。`PushKeyStore.migrateAccessibilityIfNeeded`（#392 / #656）も同型実装。なお debug（macOS は sandbox off）では再現せず、内部ベータ実機 + Sentry breadcrumb でしか追えない。

派生注意: 移行で旧 item が「読めるようになる」と、そこに残っていた **stale な値が再利用される**副作用がある。capsicum では古い `client_creds`（`capsicum://oauth` era 登録）が localhost redirect_uri で `invalid_redirect_uri` を招いた。client_creds に redirect_uri を併記し一致時のみ再利用する形で解消。

## ネイティブプッシュ（APNs / WNS）

### macOS ネイティブ APNs 配線の 3 つの罠（#468）

`FlutterAppDelegate`(FlutterMacOS) 上で APNs コールバックを実装する際、dart analyze も archive/署名も通るのに **実機起動でしか露見しない**罠が 3 つある（正本は [`AppDelegate.swift`](../packages/capsicum/macos/Runner/AppDelegate.swift) と [`Release.entitlements`](../packages/capsicum/macos/Runner/Release.entitlements) のコメント）:

1. **`override` 必須**: `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` は基底が `@MainActor open func` なので `override` を付ける（ヘッダに見えないので付け忘れやすい）。
2. **`super` を呼ばない**: しかし `super.application(...)` を呼ぶと基底がセレクタ未実装で `-[NSObject doesNotRecognizeSelector:]` → 起動時 SIGABRT クラッシュ。iOS は forwarding で救われるが macOS は override 側で完結させ super を呼ばない。
3. **entitlement キーが違う**: macOS は `com.apple.developer.aps-environment`（iOS の `aps-environment` ではない）。iOS 流のキーだと archive/署名は通るが runtime で `NSOSStatusErrorDomain code=13` になりトークン取得に失敗する。

クラッシュが TestFlight/debug いずれのビルドで起きたかは crash report の `procPath` で判別する。

### Windows WNS のバックグラウンド受信は AppContainer で DPAPI 境界を越えられない（#474）

WNS raw push のバックグラウンドタスクは FullTrust 本体とは別プロセスの **AppContainer サンドボックス**で走る。そのため roaming AppData の `flutter_secure_storage.dat`（DPAPI 暗号化）を復号できず、**登録も活性化も成功するのにプッシュ鍵が読めずトーストが出ない**。解法は push 鍵セットだけを平文 JSON 化して `ApplicationData.Current.LocalFolder`（パッケージ ACL 保護）へ同期し、bg task はそこから読む（macOS NSE の App Group 共有と同型。正本は [`local_state_files.h`](../packages/capsicum/windows/runner/local_state_files.h) / [`web_push_key_reader.h`](../packages/capsicum/windows/runner/web_push_key_reader.h)）。付随する汎用 Windows 罠: PowerShell の `[System.IO.File]::ReadAllText` は cwd 相対解決するので**絶対パス必須**、パッケージアプリは `%TEMP%` が `AC\Temp` にリダイレクトされる。

**観測結果を読むときの罠**: bg task は Sentry SDK を持てないため、診断コードは LocalState の単一スロットに書かれ、**次回アプリ起動時**に [`_flushWnsPushDiagnostics`](../packages/capsicum/lib/main.dart) が回収して送る。したがって `push.wns_bgtask: bgtask.shown` が Sentry に出ていないことは「トーストが出ていない」を意味しない（アプリを起動していないだけ）。**お知らせ通知の `bgtask.announcement_shown` も同じスロット・同じ遅延**で、#981 の実機到達確認ではこれを「Sentry に無い＝届いていない」と誤読しかけた。**逆に `bgtask.shown` が出ていれば表示まで成功している**（#957 以降。それ以前は `ShowRawToast` の戻り値を捨てて無条件に記録していたため、「復号は通ったが表示だけ失敗」が `shown` に化け、relay / WNS 側の不達と誤診する方向に倒れていた）。表示だけ失敗した場合は `bgtask.show_failed`、**起動中**の in-process 受信で同じことが起きた場合は `wns.show_failed`（runner が同じスロットへ書く）が warning で上がる。同様に、リレー側の `WNS notification dropped` は**端末がオフライン / スリープだった**という正常系で、件数の多さは不達の証拠にならない。Windows push の健全性は Sentry でなく **リレーサーバーの journald で成功ログと突き合わせて**判定する（手順の正本は [capsicum-relay の開発ガイド «配信不達の切り分け»](https://github.com/pooza/capsicum-relay/blob/main/docs/CLAUDE.md#配信不達の切り分けjournald-を読む)。誤診の経緯は [#931](https://github.com/pooza/capsicum/issues/931)）。

### プッシュ通知の重複は「上流の孤児購読」を先に疑う（#692）

「同じ通知が 2〜4 通届く」報告は、**リレー（capsicum-relay）でも配信基盤（APNs / FCM）でもなく、上流サーバー側に Web Push 購読（`sw_subscription`）が孤児として溜まっているのが原因**であることが多い。#692（2026-06 の実報告）はこれで確定した。

- **溜まり方はサーバー実装で違う**。ここが最重要で、**Mastodon と Misskey は非対称**（どちらも pooza フォークのソースで確認済み）:
  - **Mastodon** は `POST /api/v1/push/subscription` の `create` 冒頭で `destroy_web_push_subscriptions!` を呼ぶ（`app/controllers/api/v1/push/subscriptions_controller.rb`）。**1 アクセストークン = 1 購読**で、endpoint が変わっても置換される。再ログインで**トークンごと**変わったときだけ古いものが残る。
  - **Misskey** の `sw/register` は `(userId, endpoint, auth, publickey)` で探し（`findOneBy`・`packages/backend/src/server/api/endpoints/sw/register.ts`。**auth / publickey まで含めて一致**しないと別行）、無ければ **INSERT する**。**古い行は消えない**ので、endpoint が変わるたび（あるいは client が keyset を作り直すたび）に購読が 1 本増え続ける。
  - → **「Misskey だけで重複する」報告はこの非対称そのもの**。Mastodon 側が静かなことは、client が無実である証拠にならない。
- **relay は純粋な 1:1 フォワーダなので無実**。届いた購読ぶんだけ忠実に送る。relay のログで「複数回送信」が見えても、それは原因ではなく結果。
- **切り分け順序**: ①上流の購読テーブルを見て同一 endpoint / 同一ユーザーの行数を数える → ②relay の `subscriptions` を `device_type` 別に「行数 / 実アカウント数」で割り、**プラットフォーム間で比を比べる**（突出しているものが endpoint を作り直している）→ ③孤児を整理して再現するか見る。iOS と Android で症状が違って見えても**同根**のことがある（#692 がそうだった）。

**⚠ 「client 側の修正では直らない」と決めつけない（2026-08-05 に反例が出た）。**#692 の時点ではそう書いていたが、[#937](https://github.com/pooza/capsicum/issues/937) は **client が孤児を作っている側**だった —— push の endpoint は `${relayBaseUrl}/push/${push_token}` で、`push_token` は relay の行（`UNIQUE(token, account, server)`、`token` はデバイストークン）が新規作成されたときだけ発行される。**再起動をまたいでデバイストークンが変わると新しい endpoint になるが、起動経路は古い endpoint を unregister しない**（プロセス内のローテーションは `_runTokenRefresh` が正しく掃除するのに、再起動をまたぐ変化はその経路に乗らない）。Windows は WNS の channel URI が変わりやすく、relay 実測で **86 行 / 20 アカウント = 4.3** と他プラットフォーム（iOS 2.05 / Android 1.9 / macOS 1.6）から突出していた。

**⚠ この 4.3 を endpoint churn だけに帰さないこと（[#950](https://github.com/pooza/capsicum/issues/950)）。** 掃除側も効いていなかった —— `_cleanupDeviceRegistration` は「全アカウントを `unregisterAccount` → 最後に `unregisterDevice`」の順で回すが、前段の `PushKeyStore.delete(accountKey)` が **`relayId` スロットごと消す**ため、後段は保存済み id を 1 つも見つけられず `DELETE /register/:id` を**一度も発行していなかった**。孤児が増える一方で、アプリから relay row を消す経路が実質存在しない状態。加えて doc / 実装が `UNIQUE(token)`（**旧**スキーマ）の「1 行消せばデバイス全体が消える」前提のままで、現行の `UNIQUE(token, account, server)` では **N アカウント中 1 行しか消えない**形でもあった。両方 v1.55 で是正済み。

恒久対処は上流側（モロヘイヤ [#4408](https://github.com/pooza/mulukhiya-toot-proxy/issues/4408) が `sw/register` を `(userId, endpoint)` 単位で dedup）＋ relay 側の保険 dedup（[capsicum-relay#16](https://github.com/pooza/capsicum-relay/issues/16)）＋ **client 側の endpoint 安定化**（[#932](https://github.com/pooza/capsicum/issues/932) の device-id + [capsicum-relay#15](https://github.com/pooza/capsicum-relay/issues/15)）。

## CI / ビルド

### Windows: mpv アーカイブの `Integrity check failed` は一過性（再実行で通る）

`windows-release.yml` の msix ジョブが、Dart のコンパイルより手前の CMake 段階で落ちることがある。

```
CMake Error at flutter/ephemeral/.plugin_symlinks/media_kit_libs_windows_video/windows/CMakeLists.txt:43 (message):
  .../build/windows/x64/mpv-dev-x86_64-20230924-git-652a1dd.7z
  Integrity check failed, please try to re-build project again.
```

`media_kit_libs_windows_video` がビルド時に外部から取得する mpv の `.7z` が壊れていて、チェックサム検証に落ちた状態。**コード起因ではない。**`gh run rerun <id> --failed` で通る（2026-08-18 の v1.58 リリース PR で実測。1 回目 5m31s で失敗 → 再実行 17m23s で成功）。

⚠ **切り分けの手がかり**: 失敗地点が **Dart のコンパイルより前**なら、その run のコード差分は無関係とみてよい。同じツリーの直前の run が通っていればほぼ確定。

Linux 側は `libmpv-dev` を apt で入れるので、この経路は Windows 固有。**2 回続けて落ちたら一過性ではない**ので、media_kit の配布元（GitHub Releases）側か runner のネットワークを疑う。

### Windows ネイティブを触ったときの検証手順（#995 / #997 で確立）

⚠ **`develop` の CI では C++ が 1 行もコンパイルされない**（`analyze.yml` は Dart のみ）。`windows-release.yml` は native テスト **8 本すべて**をビルド・実行するが、**tag ビルドのときだけ**走る。そして **`wns_push.cpp` はどのテストにも含まれず、フルビルドでしか通らない**。つまり `windows/runner/**` を触った変更は、**実機で回すまで一度もコンパイルされないまま develop に入りうる**。

Windows 実機（[プラットフォームゲート](CLAUDE.md)の x64 端末）では次を回す:

1. **native テスト 8 本** — `vcvars64.bat` を call してから `cl /nologo /EHsc /std:c++17 <name>_test.cpp <name>.cpp`。⚠ **`notification_tag_test` だけ `/utf-8` が要る**。⚠ **cmd から exe を叩くときは `".\name.exe"` と書く**（cwd を PATH 探索しない）
2. **`cd packages/capsicum && flutter build windows --debug`** — **`wns_push.cpp` に触ったらこれが唯一のゲート**（約 5 分）。`firebase_app` の `LNK4099` 警告は既存ノイズ
3. `dart format --set-exit-if-changed .` / `dart analyze --fatal-infos` / `flutter test`。⚠ **`flutter build` 後の format は `packages/capsicum/build/` 配下の生成 Dart を拾うが gitignore 済みなので無視してよい**

⚠ **単一スロットの push 観測にコードを足すときは 2 箇所を同時に直す。** `windows/runner/push_diagnostics.cpp` の `IsBenignCode` と `packages/capsicum/lib/main.dart` の `benign` 集合は必ず揃える。片方だけだと、正常系のはずのコードが平常時の端末から毎回 warning で上がる（#997 の `wns.announcement_deduped` がその形だった）。⚠ **この一致を守る自動テストは無い**（コメントで揃えろと書いてあるだけ・[#1012](https://github.com/pooza/capsicum/issues/1012) に起票済み）。

## NodeInfo / Probing

### rel URL の判定

NodeInfo の rel URL は `http://nodeinfo.diaspora.software/ns/schema/2.0` 形式。判定は `contains('nodeinfo/2.')` ではなく `contains('/ns/schema/2.')` でマッチすること。前者は偽陽性を拾う。

## Mastodon API

### メディア ALT（description）は 2 ステップで送る

`POST /api/v1/media` の multipart リクエストに `description` を同梱しても、サーバー実装によっては保存されないことがある（モロヘイヤ経由で発生を確認済み、原因未特定）。WebUI と同じく、アップロード後に `PUT /api/v1/media/:id` で別途 `description` を設定する 2 ステップ方式を採用している。

### プロフィール編集の初期値

`GET /api/v1/accounts/verify_credentials` のトップレベル `note` は HTML 化済み。編集画面の初期値に使うと編集時に HTML タグが丸見えになる。`source.note` / `source.fields` を参照すること（プレーンテキストで返る）。

## Misskey API

### MiAuth パーミッション

新しい Misskey API エンドポイントを利用する際は `MisskeyAdapter._permissions` リストに該当パーミッションを追加すること。追加漏れは 403 `PERMISSION_DENIED` になる。既存トークンには効かないため、ユーザーは再ログインが必要。v1.2 で `read:channels` / `write:channels` / `write:report-abuse` を追加した経緯がある。

エラー時は「権限がありません。再ログインが必要な場合があります」のようなメッセージを表示する。

### `i/update` は空文字列禁止

フィールドをクリアしたい場合、空文字列 `""` は 400 エラー。JSON で明示的に `null` を送ること。キー省略は「変更なし」の意味になる。

### `sinceId` 単独指定は ASC（古い順）で返る — 下方向ページングが壊れる

Misskey 本家 `QueryService.makePaginationQuery` は **`sinceId` のみ → ASC（古い順）／`sinceId`+`untilId` → DESC／`untilId` のみ → DESC** で並べる。Mastodon は `since_id` 指定でも常に DESC のため挙動が違う。「最古 id を次ページの `maxId` にして下方向へ辿る」DESC 前提のページングを Misskey で `sinceId` 単独で回すと、1 ページ目だけ ASC になって最古側しか拾えず、新しい側を取りこぼす（v1.42 の live 復帰 catch-up #784 でこのバグを踏んだ）。**ギャップを新しい順で全件辿りたいときは `sinceId` を渡さず `maxId`（untilId）のみで DESC 取得し、下端の判定はクライアント側で行う**（`collectCatchUpGap` がこの方式）。両 SNS で DESC に揃うので分岐も消える。

### ピン留め投稿の取得

`/api/users/notes` の `pinned` パラメータは機能しない。`/api/users/show` レスポンスの `pinnedNotes` フィールドから取得すること。

### `users/report-abuse` の 500

通報受理時にサーバーが管理者へメール通知を試みる。SMTP 未設定のサーバーでは 500 Internal Error が返るが、これはサーバー側の問題であり capsicum 側の不具合ではない。

### `/api/sw/register` はサードパーティアプリから叩けない

Misskey upstream は [GHSA-7pxq-6xx9-xpgm](https://github.com/misskey-dev/misskey/security/advisories/GHSA-7pxq-6xx9-xpgm)（2023-12）で `/api/sw/register` に `secure: true` を適用しており、MiAuth / OAuth 由来のアクセストークンから叩くと HTTP **400** + `{error: {code: 'ACCESS_DENIED'}}` を返す。`secure: true` は「ブラウザのセッション Cookie（user あり + token なし）のみ許可」の意。

つまり capsicum に限らず **サードパーティアプリは Misskey の Web Push 登録を直接は行えない**。Misskey 純正アプリも `/api/sw/register` は使っておらず、Streaming API 経由の in-app 通知で代替している。

[MisskeyAdapter.subscribePush](../packages/capsicum_backends/lib/src/misskey/adapter.dart) はこの 400 を [PushRegistrationNotSupportedException](../packages/capsicum_core/lib/src/social/interfaces/push_subscription_support.dart) に詰め替え、[PushRegistrationService](../packages/capsicum/lib/src/service/push_registration_service.dart) 側は Sentry への送信をスキップする（再試行しても成功しない仕様制約で、ノイズになるため）。リレー登録のロールバックは通常ルートで実施する。

自前サーバー（ダイスキー等）向けの回避策としては、モロヘイヤにプロキシエンドポイントを生やす or フォークでガードを緩める等の選択肢がある（[#352](https://github.com/pooza/capsicum/issues/352) の follow-up 参照）。

## モロヘイヤ API

### 機能フラグは `.config.features` 配下にある（top-level `.features` ではない）

モロヘイヤ `GET /mulukhiya/api/about` の機能フラグ（`annict` / `word_suggest` / `media_catalog` / `program_editable` / `annict_linked` 等）は、**top-level の `features` ではなく `config.features` の下**にある。サーバー実装は `api_controller.rb` の `about[:config][:features] = about[:config][:features].merge(DynamicFeatures.new(sns).to_h)`。

判定するときは必ず `.config.features.<flag>` を見ること。top-level `.features` を見ると常に空に見えて「フラグが返っていない」と誤判定する。

動的フラグは `DynamicFeatures::REGISTRY` で導出される。例: `word_suggest => PronunciationDictionary.enabled?`（＝ `word_suggest/urls` 設定の有無）。capsicum 側はこのフラグで UI を出し分ける（モロヘイヤは外部 API の癖を吸収して正規化するプロキシで、capsicum は単純なフラグ判定だけを行う方針）。
