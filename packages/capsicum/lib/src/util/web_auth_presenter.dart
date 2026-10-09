import 'package:flutter/services.dart';

/// 認証シートを出す土台がまだ空いていない、という失敗か (#1260)。
///
/// iOS の `flutter_web_auth_2` は、シートを載せるビューを取れないと
/// `ACQUIRE_ROOT_VIEW_CONTROLLER_FAILED` を**即座に**返す。直前の認証シートが
/// 閉じきっていない間（キャンセル直後）は必ずこうなる。⚠ **ブラウザは開いて
/// いない**ので、キャンセルでも通信失敗でもない。
bool isWebAuthPresenterBusy(Object error) =>
    error is PlatformException &&
    error.code == 'ACQUIRE_ROOT_VIEW_CONTROLLER_FAILED';

/// [open] で認証シートを開く。土台が空いていなければ、少し待って開き直す (#1260)。
///
/// 🔴 **キャンセル直後の自動のやり直し（#620 の silent retry）が、iOS では一度も
/// 成立していなかった。**キャンセルと同じ瞬間に開き直すので、閉じかけのシートに
/// 阻まれて必ず落ち、利用者には認可コードの手入力ダイアログが出ていた
/// （Sentry `CAPSICUM-26`・2026-05 から 130 件）。
///
/// - 待つのは [isWebAuthPresenterBusy] の失敗だけ。キャンセルや通信失敗は
///   そのまま投げる（待っても結果が変わらない）。
/// - [maxAttempts] 回試しても開けなければ、最後の失敗を投げる。呼び出し側は
///   [isWebAuthPresenterBusy] で見分けて「もう一度お試しください」に倒す。
/// - [beforeRetry] は開き直す直前に呼ぶ。⚠ **待っている間に別の試行へ追い越されて
///   いたら、ここで例外を投げて止める**（待ったあとに古い試行のシートを出さない）。
Future<T> openWebAuthWhenPresenterReady<T>(
  Future<T> Function() open, {
  int maxAttempts = 5,
  Duration delay = const Duration(milliseconds: 400),
  void Function(int attempt)? beforeRetry,
}) async {
  assert(maxAttempts >= 1);
  for (var attempt = 1; ; attempt++) {
    try {
      return await open();
    } catch (e) {
      if (!isWebAuthPresenterBusy(e) || attempt >= maxAttempts) rethrow;
    }
    await Future<void>.delayed(delay);
    beforeRetry?.call(attempt + 1);
  }
}
