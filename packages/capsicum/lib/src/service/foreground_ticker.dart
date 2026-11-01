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
