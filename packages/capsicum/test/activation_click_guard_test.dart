import 'package:capsicum/src/ui/widget/activation_click_guard.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1366: ウィンドウを前面に出すためのクリックを、アプリへの操作として
/// 効かせない。
void main() {
  group('ActivationClickFilter', () {
    late Duration now;
    late ActivationClickFilter filter;

    setUp(() {
      now = Duration.zero;
      filter = ActivationClickFilter(clock: () => now);
    });

    test('前面にあるあいだの押下は捨てない', () {
      expect(filter.shouldSwallowPointerDown(), isFalse);
      expect(filter.shouldSwallowPointerDown(), isFalse);
    });

    test('前面に来た直後の最初の押下だけ捨てる（Linux の順番）', () {
      filter.onBlur();
      now = const Duration(seconds: 1);
      filter.onFocus();
      now += const Duration(milliseconds: 66); // miki の実測
      expect(filter.shouldSwallowPointerDown(), isTrue);
      now += const Duration(milliseconds: 50);
      expect(filter.shouldSwallowPointerDown(), isFalse);
    });

    test('前面に来てから間が空いた押下は捨てない（キーボードで前面に出した）', () {
      filter.onBlur();
      filter.onFocus();
      now += const Duration(milliseconds: 1300);
      expect(filter.shouldSwallowPointerDown(), isFalse);
    });

    test('締切ちょうどは捨て、過ぎたら捨てない', () {
      filter.onBlur();
      filter.onFocus();
      now += filter.window;
      expect(filter.shouldSwallowPointerDown(), isTrue);

      filter.onBlur();
      filter.onFocus();
      now += filter.window + const Duration(milliseconds: 1);
      expect(filter.shouldSwallowPointerDown(), isFalse);
    });

    test('前面に無いときの押下は捨て、その後の「前面に来た」で構え直さない', () {
      filter.onBlur();
      expect(filter.shouldSwallowPointerDown(), isTrue);
      filter.onFocus();
      now += const Duration(milliseconds: 100);
      // 利用者の 2 回目のクリック。⚠ ここで捨てると 2 回続けて効かない
      expect(filter.shouldSwallowPointerDown(), isFalse);
    });

    test('前面に来たが届き直しても構え直さない（すでに前面）', () {
      filter.onFocus(); // 初期状態で前面
      expect(filter.shouldSwallowPointerDown(), isFalse);
    });

    test('背面へ回ると構えを解く', () {
      filter.onBlur();
      filter.onFocus();
      filter.onBlur();
      filter.onFocus();
      now += const Duration(milliseconds: 10);
      expect(filter.shouldSwallowPointerDown(), isTrue);
      expect(filter.shouldSwallowPointerDown(), isFalse);
    });
  });

  group('ActivationClickGuard', () {
    late Duration now;
    late ActivationClickFilter filter;
    late int taps;
    late int scrolls;

    Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
      now = Duration.zero;
      filter = ActivationClickFilter(clock: () => now);
      taps = 0;
      scrolls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ActivationClickGuard(
            enabled: enabled,
            attachWindowManager: false,
            filter: filter,
            child: Scaffold(
              body: Listener(
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) scrolls++;
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> click(WidgetTester tester) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Scaffold)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();
    }

    testWidgets('前面に来た直後のクリックではタップが起きない', (tester) async {
      await pump(tester);
      filter.onBlur();
      filter.onFocus();
      await click(tester);
      expect(taps, 0);
    });

    testWidgets('取り消したあとのクリックは効く', (tester) async {
      await pump(tester);
      filter.onBlur();
      filter.onFocus();
      await click(tester);
      await click(tester);
      expect(taps, 1);
    });

    testWidgets('前面にあるときのクリックは効く', (tester) async {
      await pump(tester);
      await click(tester);
      expect(taps, 1);
    });

    testWidgets('前面に無いときのクリックではタップが起きない', (tester) async {
      await pump(tester);
      filter.onBlur();
      await click(tester);
      expect(taps, 0);
    });

    testWidgets('前面に無いときもホイールは届く', (tester) async {
      await pump(tester);
      filter.onBlur();
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(Scaffold))),
      );
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
      await tester.pump();
      expect(scrolls, 1);
      // ホイールでは構えが消費されない ＝ 次のクリックは捨てる
      await click(tester);
      expect(taps, 0);
    });

    testWidgets('enabled が false なら何もしない（モバイル）', (tester) async {
      await pump(tester, enabled: false);
      filter.onBlur();
      await click(tester);
      expect(taps, 1);
    });
  });
}
