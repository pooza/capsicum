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
/// リトライ窓は既定 6 回・合計約 2.25s（`150ms * attempt` の累積）。#813 当初の
/// 3 回・約 450ms では吸収しきれない端末があることが計装で判明したため広げた
/// （#859）。CAPSICUM-3Q の実測では枯渇イベントの errno は 100% が
/// EADDRINUSE(98) で、同一ユーザーが複数サーバへログインできている＝ポートの
/// 恒久占有ではなく一過性。dart:io は SO_REUSEADDR を既定で立てるため TIME_WAIT
/// ではなく、`close(force:true)` の Future 完了後も OS のソケット解放が遅れて
/// 直後の再 bind が撥ねられる（OnePlus 8 Pro / Android 11 で顕著）自プロセス
/// 残存が主因とみて、窓を延ばして解放を待つ。特定端末向けの分岐は入れない
/// （#824 と同じ汎用堅牢化の範囲）。効果は CAPSICUM-3Q の post-release 観測で
/// 回収する。それでも残るなら「別プロセスの恒久占有」を疑い UX 手当てへ倒す。
///
/// [sleep] はテスト用の差し込み口（既定は [Future.delayed]）。バックオフ中に
/// ポートを解放して「数回目で成功」する経路を検証できる。
Future<HttpServer> bindLoopbackOAuthServer(
  int port, {
  int maxAttempts = 6,
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
