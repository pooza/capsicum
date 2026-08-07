/// アダプター本体の Dio に当てる既定タイムアウト (#900)。
///
/// Dio の既定は**タイムアウト無し**なので、設定しないと応答しないサーバーに
/// 当たった経路が OS の TCP タイムアウト（分単位になりうる）まで待ち続ける。
///
/// ## 値の考え方
///
/// probing / server_info 等が使う 5 秒（アプリ側 `constants.dart` の
/// `kNetworkConnectTimeout` / `kNetworkReceiveTimeout`）より**緩くする**。
/// あちらは「繋がらないサーバーを早く見切る」のが目的だが、こちらは日常の
/// 全 API 経路に効くため、モバイル回線や重いサーバーで**動いている通信まで
/// 切ってしまう**方が害が大きい。狙いは「分単位のハングを止める」ことだけ。
///
/// ## receiveTimeout / sendTimeout の実際の意味（dio 5.11 の実装で確認）
///
/// `BaseOptions` の doc は「バイトイベントの間隔」としか書いていないが、
/// dart:io アダプタの実装は 2 箇所で使い分けている。**値を触る前にここを読むこと**。
///
/// - `receiveTimeout` は次の**両方**に効く:
///   1. `request.close()` の future、すなわち**レスポンスヘッダー到達までの絶対上限**
///      (`adapters/io_adapter.dart`)。サーバーが計算している時間はここに入るので、
///      短く取ると「サーバーは返せるのに client が先に切る」が起きる
///   2. body 転送中の**チャンク間隔**（`response/response_stream_handler.dart` の、
///      チャンクごとにリセットされる Timer）。転送が進んでいれば切れない
///
///   「分単位のハングを止める」という #900 の狙いは 2 で達成される。1 は副作用なので、
///   **サーバー側が同期処理を行う経路の所要時間より長く**取る必要がある。実測の下限は
///   Mastodon の翻訳（`TranslationService` は `Request::TIMEOUT` = connect 5 +
///   read 30 = 35 秒）と `search(resolve: true)`（WebFinger + AP フェッチが直列）。
///   美食丼の nginx は `proxy_read_timeout` 未指定＝既定 60 秒。
///
/// - `sendTimeout` は間隔ではなく、**送信ボディ全体の壁時計上限**
///   （`request.addStream()` 全体に `.timeout()` を掛けている）。アップロード用の値は
///   「最大ファイルサイズ ÷ 想定される最低の上り速度」で決める。
///
/// ## RateLimitInterceptor との関係
///
/// `RateLimitInterceptor` は 429 のバックオフ待ちと reset 先回り待ちを
/// **インターセプタ内の `Future.delayed`** で行う。Dio のタイムアウトは
/// インターセプタ連鎖の後段（`_dispatchRequest` 以降のトランスポート）にしか
/// 効かないため、**待ちがタイムアウトで打ち切られることはない**。
library;

/// 接続確立まで。モバイル回線の TLS ハンドシェイクを見込んで緩めに取る。
const kAdapterConnectTimeout = Duration(seconds: 15);

/// ヘッダー到達までの上限、かつ body のチャンク間隔。
///
/// サーバー側が同期で外部フェッチを行う経路（Mastodon の翻訳 = 最大 35 秒、
/// `search(resolve: true)` の WebFinger + AP フェッチ）を切らないため、
/// 美食丼の nginx 既定 `proxy_read_timeout` と同じ 60 秒に合わせる。
const kAdapterReceiveTimeout = Duration(seconds: 60);

/// 送信ボディ全体の壁時計上限。本文の無い GET には効かない。
/// 通常の投稿・API 呼び出しのボディは小さいので 30 秒で足りる。
const kAdapterSendTimeout = Duration(seconds: 30);

/// ファイル転送を伴う経路（メディアアップロード / アバター・ヘッダー更新）用の
/// 緩いタイムアウト (#900)。
///
/// 送信そのものが長いうえ、**サーバー側の変換待ちで最初の応答バイトまでが長い**
/// （Misskey のドライブ登録など）。既定値のままだと正常なアップロードを切って
/// しまうため、呼び出し側で `Options` に当てて上書きする。
///
/// `sendTimeout` は上記のとおり**送信の総時間**なので、値は回線速度から決める。
/// サーバー上限に近い 40MB の動画を上り 500kbps のモバイル回線で送ると約 11 分
/// かかる計算で、5 分では正常なアップロードを切ってしまう（v1.53 まではタイムアウト
/// 未設定＝無制限だったため、時間をかければ通っていた）。余裕を見て 20 分。
const kAdapterUploadTimeout = Duration(minutes: 20);
