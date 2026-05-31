import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// マウスドラッグでも横スクロール要素 (Drawer / TabBar 等) を掴めるように
/// する [MaterialScrollBehavior] (#574)。
///
/// デフォルトの [MaterialScrollBehavior.dragDevices] はタッチ / スタイラスに
/// 限定されており、マウスは「ホイール / トラックパッド 2 本指」しか効かない。
/// 本クラスを `ScrollConfiguration(behavior:)` で噛ませると mouse も
/// dragDevices に加わり、PC で「タブを掴んで横へ引く」操作が成立する。
///
/// 代償として macOS / Linux のトラックパッド 2 本指スワイプとの両立が
/// 崩れるケースがあるため、利用側は [mouseDragScrollProvider] のオプトイン
/// 値で分岐させること。
class MouseDragScrollBehavior extends MaterialScrollBehavior {
  const MouseDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}
