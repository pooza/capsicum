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
/// ## receiveTimeout は総時間ではない
///
/// Dio の `receiveTimeout` は「接続確立〜最初の応答バイトまで」と「データ転送中の
/// **各バイトイベントの間隔**」であって、受信全体の総時間ではない
/// （`BaseOptions.receiveTimeout` の doc）。したがって 30 秒は「30 秒間まったく
/// 音沙汰が無ければ切る」であり、大きなレスポンスでも転送が進んでいれば切れない。
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

/// 応答の受信間隔。上記のとおり総時間ではない。
const kAdapterReceiveTimeout = Duration(seconds: 30);

/// リクエスト送信の間隔。本文の無い GET には効かない。
const kAdapterSendTimeout = Duration(seconds: 30);

/// ファイル転送を伴う経路（メディアアップロード / アバター・ヘッダー更新）用の
/// 緩いタイムアウト (#900)。
///
/// 送信そのものが長いうえ、**サーバー側の変換待ちで最初の応答バイトまでが長い**
/// （Misskey のドライブ登録など）。既定値のままだと正常なアップロードを切って
/// しまうため、呼び出し側で `Options` に当てて上書きする。
const kAdapterUploadTimeout = Duration(minutes: 5);
