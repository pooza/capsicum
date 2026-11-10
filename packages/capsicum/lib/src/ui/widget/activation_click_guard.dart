import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// ウィンドウを前面に出すためのクリックを、アプリへの操作として効かせない
/// ための判定 (#1366)。
///
/// 捨てるのは次の 2 つの**押下**だけ:
///
/// 1. **前面に無いときの押下**（押下のあとで「前面に来た」が届く OS 向け）
/// 2. **前面に来てから [window] 以内の、最初の押下**（「前面に来た」が押下より
///    先に届く OS 向け）。⚠⚠ **Linux（LXQt / openbox・X11）はこちら**で、
///    `onWindowFocus` が押下の約 66ms 前に届く（2026-11-10 に miki で実測）。
///    「前面に無いときの押下」だけでは見分けられない
///
/// ⚠ **ホイール・トラックパッドのスクロールは押下ではないので捨てない**
/// （前面に出さなくても読めるように・Issue の決めごと）。
///
/// ⚠ **キーボード（⌘Tab / Alt+Tab）で前面に出したあとのクリックは捨てない。**
/// 前面に来た時刻からの間で見分けるので、[window] より後のクリックは効く。
/// ⚠ [window] を広げすぎると、切り替えた直後に素早く押したクリックまで捨てる。
/// 実測の 66ms に余裕を見て 300ms にした。
///
/// ⚠ **macOS も最初のクリックをアプリへ渡す。**Flutter 3.47.9 のエンジンの
/// `FlutterView` は `acceptsFirstMouse:` で `YES` を返す（2026-11-10 にソースで
/// 確認）ので、macOS にもこの手当てが要る。⚠ 押下と「前面に来た」の順番は
/// macOS ではまだ測っていないが、1 と 2 でどちらの順番にも効く。
/// ⚠ 仮に最初のクリックが届かない作りに変わっても、2 は [window] が過ぎれば
/// 外れるので、次のクリックは効く。
class ActivationClickFilter {
  ActivationClickFilter({
    Duration Function()? clock,
    this.window = const Duration(milliseconds: 300),
    bool initiallyFocused = true,
  }) : _clock = clock ?? _defaultClock,
       _focused = initiallyFocused;

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static Duration _defaultClock() => _stopwatch.elapsed;

  final Duration Function() _clock;

  /// 前面に来てから、押下を「前面に出すためのクリック」と見なす間。
  final Duration window;

  bool _focused;

  /// 前面に来た直後の、まだ押下が来ていない間の締切。
  Duration? _armedUntil;

  /// 前面に無いときの押下を捨てたか。⚠ その直後に届く「前面に来た」で
  /// もう一度構えると、**利用者の 2 回目のクリックまで捨てる**ので、構えない。
  bool _swallowedWhileBlurred = false;

  bool get focused => _focused;

  void onFocus() {
    if (_focused) return;
    _focused = true;
    _armedUntil = _swallowedWhileBlurred ? null : _clock() + window;
    _swallowedWhileBlurred = false;
  }

  void onBlur() {
    _focused = false;
    _armedUntil = null;
    _swallowedWhileBlurred = false;
  }

  /// 押下を捨てるなら true。
  bool shouldSwallowPointerDown() {
    if (!_focused) {
      _swallowedWhileBlurred = true;
      return true;
    }
    final armedUntil = _armedUntil;
    _armedUntil = null;
    return armedUntil != null && _clock() <= armedUntil;
  }
}

/// [ActivationClickFilter] をアプリ全体（タブ UI・デッキ UI とも）に掛ける
/// (#1366)。`MaterialApp.builder` で一番外に置く。
///
/// 捨てると決めた押下は [GestureBinding.cancelPointer] で取り消す。
/// ⚠ **押下そのものはもう子へ配られている**（[Listener] は深い順に呼ばれ、
/// ここはいちばん外）。取り消しはタップ・長押し・ドラッグを成立させないだけで、
/// **押下の時点で動く `onPointerDown` は止められない**。2026-11-10 時点で
/// 押下で動くのはデッキのカラムのフォーカス（`deck_column_focus.dart`）だけで、
/// 何かを開くものではない。⚠ **押下で画面を開くハンドラーを足すと、この守りを
/// すり抜ける。**
class ActivationClickGuard extends StatefulWidget {
  const ActivationClickGuard({
    super.key,
    required this.child,
    this.enabled = true,
    this.attachWindowManager = true,
    this.filter,
  });

  final Widget child;

  /// false なら何もしない（モバイル）。
  final bool enabled;

  /// `window_manager` の前面 / 背面の通知を受けるか。⚠ テストでは false にして
  /// [filter] を直接動かす（チャンネルが無い）。
  final bool attachWindowManager;

  /// テスト用。省略時は既定の時計で作る。
  final ActivationClickFilter? filter;

  @override
  State<ActivationClickGuard> createState() => _ActivationClickGuardState();
}

class _ActivationClickGuardState extends State<ActivationClickGuard>
    with WindowListener {
  late final ActivationClickFilter _filter =
      widget.filter ?? ActivationClickFilter();

  bool get _listening => widget.enabled && widget.attachWindowManager;

  @override
  void initState() {
    super.initState();
    if (_listening) {
      windowManager.addListener(this);
      // ⚠ 起動直後の状態が分からない間は「前面にある」と見なす（捨てない側）。
      windowManager.isFocused().then((focused) {
        if (!mounted) return;
        focused ? _filter.onFocus() : _filter.onBlur();
      }, onError: (Object _) {});
    }
  }

  @override
  void dispose() {
    if (_listening) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowFocus() => _filter.onFocus();

  @override
  void onWindowBlur() => _filter.onBlur();

  void _handlePointerDown(PointerDownEvent event) {
    if (_filter.shouldSwallowPointerDown()) {
      GestureBinding.instance.cancelPointer(event.pointer);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      child: widget.child,
    );
  }
}
