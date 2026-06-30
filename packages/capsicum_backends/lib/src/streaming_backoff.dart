import 'dart:math';

/// ストリーミング再接続のバックオフ間隔（ミリ秒）を計算する (#784)。
///
/// [attempt] は 0 始まりの試行回数。指数バックオフ（[baseMs] * 2^attempt）を
/// [maxMs] で頭打ちにし、**equal jitter**（固定半分＋ランダム半分）を載せる。
/// jitter は実況で多数のクライアントが同じサーバー断のあと**一斉に再接続して
/// サーバーを再度詰まらせる thundering herd** を緩和するために入れる。
///
/// 諦めずに再試行を続ける設計（[attempt] が無限に増えうる）なので、指数は内部で
/// クランプして `1 << exp` の overflow を防ぐ。返り値は常に
/// `[computed/2, computed]`（computed は `[baseMs, maxMs]` 内）に収まる。
int reconnectBackoffMs(
  int attempt, {
  required int baseMs,
  required int maxMs,
  Random? random,
}) {
  final exp = attempt < 0
      ? 0
      : (attempt > 16 ? 16 : attempt); // 2^16 で十分 maxMs に到達・overflow 回避
  final computed = (baseMs * (1 << exp)).clamp(baseMs, maxMs);
  final half = computed ~/ 2;
  final jitter = half <= 0 ? 0 : (random ?? Random()).nextInt(half + 1);
  return half + jitter;
}
