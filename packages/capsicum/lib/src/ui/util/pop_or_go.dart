import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// 画面を閉じる。閉じる先が無いとき（深いリンクで直接開いたなど）だけ
/// [fallback] へ出す (#1319 / #1332)。
///
/// ⚠⚠ **`go` で置き換えるところから始めない。**デッキ（`/deck`）は `/home` の
/// 上に push した画面なので、`go('/home')` / `go('/chat')` で積み重ねを
/// 置き換えると `/deck` ごと消えてタブ表示に落ちる。
/// `stack_replacing_navigation_guard_test` が見ている。
void popOrGo(BuildContext context, String fallback, {Object? result}) {
  if (context.canPop()) {
    context.pop(result);
  } else {
    context.go(fallback);
  }
}
