/// 再接続のテストが共有する、「つないでも必ず失敗する」ローカルのポート (#1301)。
///
/// ## なぜ閉じたポートを使わないのか
///
/// ⚠⚠ **Windows では、閉じたループバックのポートへの接続は拒否されるまで約 2 秒
/// かかる**（2026-10-24 に x64 機で実測・errno 1225。SYN を再送してから諦める）。
/// macOS / Linux はすぐに拒否されるので、「bind してすぐ close したポート」で
/// 失敗を作ると、**5 秒で 25 回の再接続を見るテストが Windows でだけ 2〜3 回で
/// 時間切れになる**（`notification_streaming_reconnect_test` /
/// `misskey_chat_streaming_reconnect_test` の 6 件が落ちていた）。CI（Linux）は緑。
///
/// ここでは**受けた瞬間に切る**サーバーを立てる。WebSocket の握手の前に接続が
/// 切れるので、どの OS でもすぐ失敗する。⚠ 失敗の種類は「拒否」ではなく
/// 「握手の前に切れた」になるが、再接続のテストが見ているのは**失敗の数え方と
/// 予約**で、どの経路（`stream` の onError / onDone と `ready` の catchError）から
/// 届くかは同じ。
library;

import 'dart:io';

class RefusingPort {
  RefusingPort._(this._server);

  final ServerSocket _server;

  int get port => _server.port;

  /// 空いているポートで立てる。テストの終わりには [close] を呼ぶこと。
  static Future<RefusingPort> open() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) => socket.destroy());
    return RefusingPort._(server);
  }

  /// 閉じてポートを空ける。**同じポートでサーバーを立て直す前**（回線が戻った
  /// ことを作るとき）にも呼ぶ。2 度呼んでもよい。
  Future<void> close() => _server.close();
}
