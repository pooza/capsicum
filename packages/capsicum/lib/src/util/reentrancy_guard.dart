import 'dart:async';

/// 非同期処理の再入ガード (#908)。
///
/// 「処理中フラグを立てて UI を無効化する」だけでは、**フラグを立てるより前に
/// await がある**と守れない。投稿の送信がこれで、`_sending` を立てるのは確認設定の
/// 読み出し（SharedPreferences）を await した後だったため、その往復の間はボタンが
/// 有効なままで、素早い二連打が二重投稿になりえた。
///
/// [run] は **最初の await より前に同期的に**フラグを立てるので、この窓が無い。
/// 走行中の再呼び出しは黙って捨てる（キューには積まない — 送信は「押した回数だけ
/// 実行する」操作ではない）。
///
/// UI のスピナー用フラグとは役割が別なので分けて持つ。こちらは setState を伴わず、
/// 再描画も起こさない。
class ReentrancyGuard {
  bool _inFlight = false;

  /// 走行中か。呼び出し側で「押しても無駄」を先に弾きたいときに使う。
  bool get inFlight => _inFlight;

  /// 走行中でなければ [action] を実行する。走行中なら何もしない。
  ///
  /// [action] が投げた場合もフラグは戻す（次回の操作が永久に弾かれないように）。
  /// 例外はそのまま呼び出し側へ伝える。
  Future<void> run(Future<void> Function() action) async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      await action();
    } finally {
      _inFlight = false;
    }
  }
}
