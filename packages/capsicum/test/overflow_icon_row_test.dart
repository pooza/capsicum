import 'package:capsicum/src/ui/widget/overflow_icon_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1167: 投稿画面の下のアイコン列を、幅に応じて「…」へ畳む。
///
/// ⚠⚠ **横スクロールをやめるのが趣旨。**デスクトップは横スクロールに気付きにくく
/// 操作もしにくいので、はみ出た分は実質的に届かない場所になっていた。
void main() {
  List<OverflowIconAction> actions(int n, {Set<int> active = const {}}) => [
    for (var i = 0; i < n; i++)
      OverflowIconAction(
        key: 'a$i',
        icon: const Icon(Icons.circle),
        tooltip: '操作 $i',
        onPressed: () {},
        active: active.contains(i),
      ),
  ];

  Future<void> pump(
    WidgetTester tester, {
    required double width,
    required List<OverflowIconAction> items,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: OverflowIconRow(actions: items),
        ),
      ),
    ),
  );

  Finder visible(String key) => find.byKey(ValueKey('compose-action-$key'));
  final overflow = find.byKey(const ValueKey('compose-action-overflow'));

  group('visibleCountFor', () {
    test('全部入るなら全部', () {
      expect(
        OverflowIconRow.visibleCountFor(width: 400, total: 5, itemExtent: 40),
        5,
      );
    });

    test('ぴったりなら全部（「…」は出さない）', () {
      expect(
        OverflowIconRow.visibleCountFor(width: 200, total: 5, itemExtent: 40),
        5,
      );
    });

    test('⚠ あふれるなら「…」のぶんを 1 つ取っておく', () {
      // 5 個ぶんの幅に 6 個。⚠ 5 個出すと「…」が 6 個目に並んでまたあふれる。
      expect(
        OverflowIconRow.visibleCountFor(width: 200, total: 6, itemExtent: 40),
        4,
      );
    });

    test('⚠ 幅が 1 つぶんも無ければ全部畳む（負にしない）', () {
      expect(
        OverflowIconRow.visibleCountFor(width: 30, total: 6, itemExtent: 40),
        0,
      );
    });

    test('1 つぶんしか無ければ「…」だけ', () {
      expect(
        OverflowIconRow.visibleCountFor(width: 40, total: 6, itemExtent: 40),
        0,
      );
    });

    test('0 個なら 0', () {
      expect(
        OverflowIconRow.visibleCountFor(width: 400, total: 0, itemExtent: 40),
        0,
      );
    });
  });

  testWidgets('広い幅なら全部並び、「…」は出ない', (tester) async {
    await pump(tester, width: 400, items: actions(5));

    expect(visible('a0'), findsOneWidget);
    expect(visible('a4'), findsOneWidget);
    expect(overflow, findsNothing);
  });

  testWidgets('⚠ 狭いとあふれたぶんが「…」へ入り、並びは変わらない', (tester) async {
    await pump(tester, width: 200, items: actions(6));

    // 4 個 + 「…」。
    expect(visible('a0'), findsOneWidget);
    expect(visible('a3'), findsOneWidget);
    expect(visible('a4'), findsNothing);
    expect(overflow, findsOneWidget);

    await tester.tap(overflow);
    await tester.pumpAndSettle();

    expect(find.text('操作 4'), findsOneWidget);
    expect(find.text('操作 5'), findsOneWidget);
    // ⚠ 見えているぶんはメニューに出さない（二重に出さない）。
    expect(find.text('操作 0'), findsNothing);
  });

  testWidgets('畳んだ側からも押せる', (tester) async {
    var pressed = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: OverflowIconRow(
              actions: [
                for (var i = 0; i < 6; i++)
                  OverflowIconAction(
                    key: 'a$i',
                    icon: const Icon(Icons.circle),
                    tooltip: '操作 $i',
                    onPressed: () => pressed = 'a$i',
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(overflow);
    await tester.pumpAndSettle();
    await tester.tap(find.text('操作 5'));
    await tester.pumpAndSettle();

    expect(pressed, 'a5');
  });

  testWidgets('⚠⚠ 畳んだ中に効いているものがあれば「…」に印が付く', (tester) async {
    // 効いているのは 5 番目（畳まれる側）。
    await pump(tester, width: 200, items: actions(6, active: {5}));

    final icon = tester.widget<Icon>(
      find.descendant(of: overflow, matching: find.byIcon(Icons.more_horiz)),
    );
    expect(
      icon.color,
      isNotNull,
      reason: '⚠ 印が無いと「閲覧注意が ON なのに画面のどこにも出ていない」状態になる',
    );
  });

  testWidgets('⚠ 効いているものが見えているなら「…」に印は付けない', (tester) async {
    // 効いているのは 0 番目（見えている側）。
    await pump(tester, width: 200, items: actions(6, active: {0}));

    final icon = tester.widget<Icon>(
      find.descendant(of: overflow, matching: find.byIcon(Icons.more_horiz)),
    );
    expect(icon.color, isNull);
  });

  testWidgets('⚠ 押せない操作は畳んだ側でも押せない（送信中）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: OverflowIconRow(
              actions: [
                for (var i = 0; i < 6; i++)
                  OverflowIconAction(
                    key: 'a$i',
                    icon: const Icon(Icons.circle),
                    tooltip: '操作 $i',
                    onPressed: null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(overflow);
    await tester.pumpAndSettle();

    final item = tester.widget<PopupMenuItem<OverflowIconAction>>(
      find.byKey(const ValueKey('compose-overflow-a5')),
    );
    expect(item.enabled, isFalse);
  });

  testWidgets('⚠ 375px でも overflow しない（狭幅運用が前提）', (tester) async {
    await pump(tester, width: 375, items: actions(14));

    expect(tester.takeException(), isNull);
    expect(overflow, findsOneWidget);
  });
}
