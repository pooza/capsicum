import 'dart:async';
import 'dart:io';

/// loopback OAuth コールバック用サーバの bind に固定ポートで失敗し続けたことを
/// 表す（#813）。ほぼ EADDRINUSE（他プロセス/自プロセスの残存リスナがポートを
/// 掴んでいる）で、UI 層はこれを捕捉して「ポート占有」の友好エラーに昇格させる。
class LoopbackPortOccupiedException implements Exception {
  final int port;

  /// リトライを使い切ったときの最後の bind エラー（観測用）。
  final Object? lastError;

  const LoopbackPortOccupiedException(this.port, [this.lastError]);

  @override
  String toString() =>
      'LoopbackPortOccupiedException(port: $port, lastError: $lastError)';
}

Duration _defaultBackoff(int attempt) => Duration(milliseconds: 150 * attempt);

/// 固定ポート [port] に loopback (127.0.0.1) の [HttpServer] を bind する。
/// EADDRINUSE 等の [SocketException] で失敗したら短いバックオフを挟んで
/// [maxAttempts] 回まで再試行し、それでも駄目なら
/// [LoopbackPortOccupiedException] を投げる（#813）。
///
/// 直前のログイン試行のサーバがまだ完全に解放されていない一時的な競合を吸収
/// するのが目的。呼び出し側は bind 前に自分の旧サーバを閉じておくこと（残存
/// リスナ自体はここでは面倒を見ない）。
///
/// [sleep] はテスト用の差し込み口（既定は [Future.delayed]）。バックオフ中に
/// ポートを解放して「数回目で成功」する経路を検証できる。
Future<HttpServer> bindLoopbackOAuthServer(
  int port, {
  int maxAttempts = 3,
  Duration Function(int attempt) backoff = _defaultBackoff,
  Future<void> Function(Duration) sleep = Future.delayed,
}) async {
  assert(maxAttempts >= 1);
  Object? lastError;
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    if (attempt > 0) await sleep(backoff(attempt));
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (e) {
      lastError = e;
    }
  }
  throw LoopbackPortOccupiedException(port, lastError);
}
