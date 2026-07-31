import 'package:capsicum/src/ui/util/keyboard_list_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// #849: タイムライン / スレッドの ↑ ↓ キーナビゲーション。
///
/// ホームとスレッドは同じ mixin を共有するので、mixin 単体をリスト付きの最小
/// ハーネスで検証する。押した回数どおりにカーソルが動き、両端で止まり、修飾
/// キー付きは上位（メニューバーのショートカット）へ流すことを担保する。
class _Harness extends StatefulWidget {
  final int itemCount;
  final ValueChanged<int> onActivate;

  const _Harness({required this.itemCount, required this.onActivate});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with KeyboardListNavigation {
  final _controller = ItemScrollController();
  final _positions = ItemPositionsListener.create();

  @override
  ItemScrollController get keyboardListScrollController => _controller;

  @override
  ItemPositionsListener get keyboardListPositionsListener => _positions;

  @override
  int get keyboardListItemCount => widget.itemCount;

  @override
  void onKeyboardListActivate(int index) => widget.onActivate(index);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: wrapKeyboardListNavigation(
            child: ScrollablePositionedList.separated(
              itemScrollController: _controller,
              itemPositionsListener: _positions,
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) => SizedBox(
                height: 100,
                child: Text(
                  'item $index${keyboardSelectedIndex == index ? ' [selected]' : ''}',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  Future<_HarnessState> pumpHarness(
    WidgetTester tester, {
    int itemCount = 10,
    ValueChanged<int>? onActivate,
  }) async {
    await tester.pumpWidget(
      _Harness(itemCount: itemCount, onActivate: onActivate ?? (_) {}),
    );
    // mixin は初回フレーム後にフォーカスを取りにいく。
    await tester.pumpAndSettle();
    return tester.state<_HarnessState>(find.byType(_Harness));
  }

  testWidgets('選択は null 始点で、最初の ↓ で先頭が選ばれる', (tester) async {
    final state = await pumpHarness(tester);
    expect(state.keyboardSelectedIndex, isNull);
    expect(find.text('item 0 [selected]'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(state.keyboardSelectedIndex, 0);
    expect(find.text('item 0 [selected]'), findsOneWidget);
  });

  testWidgets('↓ ↑ で 1 件ずつ動き、両端で止まる', (tester) async {
    final state = await pumpHarness(tester, itemCount: 3);

    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    // 先頭を選ぶ 1 回 + 2 件分の移動で末尾に到達し、それ以上は進まない。
    expect(state.keyboardSelectedIndex, 2);

    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
    }
    expect(state.keyboardSelectedIndex, 0);
  });

  testWidgets('Enter / → は選択中の要素を開く', (tester) async {
    final activated = <int>[];
    final state = await pumpHarness(tester, onActivate: activated.add);

    // 未選択のうちは何も開かない。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(activated, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(state.keyboardSelectedIndex, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(activated, [1, 1]);
  });

  testWidgets('修飾キー付きの ↑ ↓ は扱わない（上位のショートカットへ流す）', (tester) async {
    final state = await pumpHarness(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(state.keyboardSelectedIndex, isNull);
  });

  testWidgets('リストが空なら何も起きない', (tester) async {
    final state = await pumpHarness(tester, itemCount: 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(state.keyboardSelectedIndex, isNull);
  });

  testWidgets('resetKeyboardSelection で選択が消える（タブ切替相当）', (tester) async {
    final state = await pumpHarness(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(state.keyboardSelectedIndex, 0);

    state.resetKeyboardSelection();
    await tester.pumpAndSettle();
    expect(state.keyboardSelectedIndex, isNull);
    expect(find.text('item 0 [selected]'), findsNothing);
  });
}
