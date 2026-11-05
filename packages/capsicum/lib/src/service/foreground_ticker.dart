import 'dart:async';

import 'package:flutter/widgets.dart';

/// アプリが前面にいる間だけ [onTick] を一定の間隔で呼ぶ (#910)。
///
/// 背面へ回ったら止め、戻ったら間隔を数え直す（戻った瞬間の取り直しは、呼ぶ側の
/// 復帰の処理が別に持っている）。
class ForegroundTicker {
  ForegroundTicker({required this.interval, required this.onTick});

  final Duration interval;
  final VoidCallback onTick;

  Timer? _timer;

  bool get isRunning => _timer != null;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => onTick());
  }

  /// 作り直したときの始め方 (#1361)。アプリが前面（[AppLifecycleState.resumed]）に
  /// いるときだけ始める。⚠ 無条件に [start] すると、裏にいる間に画面が作り直された
  /// とき（アカウントの切り替えなど）に動き出し、裏で取り直し続ける。
  ///
  /// [state] が null（起動の直後でまだ分からない）なら、前面とみなして始める。
  /// 裏にいたなら、次の [handleLifecycle] で止まる。
  void startIfResumed(AppLifecycleState? state) {
    if (state == null || state == AppLifecycleState.resumed) start();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// [state] に合わせて動かす。⚠ `inactive` では止めない（通知センターを少し
  /// 引いただけでも入り、前面に居続けている扱いのほうが実態に近い）。
  void handleLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        start();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        stop();
      case AppLifecycleState.inactive:
        break;
    }
  }
}
