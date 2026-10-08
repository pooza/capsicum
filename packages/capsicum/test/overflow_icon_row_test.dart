import 'package:capsicum/src/ui/widget/overflow_icon_row.dart';
import 'package:flutter/gestures.dart';
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

  group('流す形 (#1167・2026-09-30 の A+C)', () {
    late ScrollController controller;

    setUp(() => controller = ScrollController());
    tearDown(() => controller.dispose());

    Future<void> pumpScrolling(
      WidgetTester tester, {
      required double width,
      required int count,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: ScrollingIconRow(
              actions: actions(count),
              controller: controller,
            ),
          ),
        ),
      ),
    );

    testWidgets('⚠⚠ 残り幅が 1 つぶんでも、全部のアイコンが列に載っている', (tester) async {
      // ⚠⚠ **畳む形との決定的な違い。**`OverflowIconRow` は残り幅から「何個入るか」
      // を決めるので、設定に幅を取られると 0 個になる（13 mini で実際にそうなった）。
      // 流す形は**幅に関係なく全部を列へ載せ**、見えないぶんはスクロールで届く。
      await pumpScrolling(tester, width: 40, count: 11);

      expect(tester.takeException(), isNull);
      for (var i = 0; i < 11; i++) {
        expect(visible('a$i'), findsOneWidget, reason: 'a$i が列から落ちている');
      }
      // 畳む側の入口は出ない（畳んでいないので）。
      expect(overflow, findsNothing);
    });

    testWidgets('⚠ スクロールバーを常時出す（「気付けない」が元の不満）', (tester) async {
      await pumpScrolling(tester, width: 200, count: 11);

      final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      expect(
        scrollbar.thumbVisibility,
        isTrue,
        reason: '⚠⚠ 触るまで出ないスクロールバーでは、横スクロールの弱点を直したことにならない',
      );
    });

    testWidgets('⚠⚠ マウス / トラックパッドでもドラッグできる', (tester) async {
      await pumpScrolling(tester, width: 200, count: 11);

      // ⚠⚠ **既定の `ScrollBehavior` は `mouse` を外している。**これが
      // 「デスクトップではドラッグでもスクロールしない」の正体で、#1167 が
      // 横スクロールを捨てた理由だった。⚠ ホイールは縦にしか回らないので
      // 横方向の代わりにならない。
      final view = tester.element(find.byType(SingleChildScrollView));
      final devices = ScrollConfiguration.of(view).dragDevices;
      expect(devices, contains(PointerDeviceKind.mouse));
      expect(devices, contains(PointerDeviceKind.trackpad));
      expect(devices, contains(PointerDeviceKind.touch));
    });

    testWidgets('実際に横へ流れる', (tester) async {
      await pumpScrolling(tester, width: 120, count: 11);

      final before = tester.getTopLeft(visible('a0')).dx;
      controller.jumpTo(120);
      await tester.pump();
      expect(tester.getTopLeft(visible('a0')).dx, lessThan(before));
    });

    testWidgets('⚠⚠ 指のドラッグで流れる', (tester) async {
      // ⚠⚠ **`controller.jumpTo` で動くことは、指で動くことを意味しない。**
      // 2026-09-30 に実機で「スワイプできない」と報告され、`jumpTo` の検査だけ
      // 通っていたことが分かった。**機構ではなくジェスチャを見ること。**
      await pumpScrolling(tester, width: 160, count: 11);

      expect(controller.offset, 0);
      await tester.drag(
        find.byType(ScrollingIconRow),
        const Offset(-120, 0),
        // ⚠ 実機の指と同じ種類で引く（既定は touch だが明示しておく）。
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();

      expect(
        controller.offset,
        greaterThan(0),
        reason: '⚠⚠ 指で引いても動かないなら、届かないアイコンができる',
      );
    });

    testWidgets('⚠ アイコンの上から引いても流れる（ボタンが取らない）', (tester) async {
      // ⚠ 実機で指が触れるのはアイコンの上。ボタンの上から引いて動かなければ、
      // 「スクロールできる」と言えない。
      await pumpScrolling(tester, width: 160, count: 11);

      await tester.drag(
        visible('a1'),
        const Offset(-120, 0),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();

      expect(controller.offset, greaterThan(0));
    });

    testWidgets('⚠ マウスで引いても流れる（デスクトップの元の不満）', (tester) async {
      await pumpScrolling(tester, width: 160, count: 11);

      await tester.drag(
        visible('a1'),
        const Offset(-120, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(controller.offset, greaterThan(0));
    });

    testWidgets('⚠⚠ 投稿画面と同じ入れ子（右端に設定を置いた Row）でも引ける', (tester) async {
      // ⚠⚠ **単体で動くことは、画面の中で動くことを意味しない。**2026-09-30 に
      // 実機で「スワイプできない」と報告された。単体のドラッグ検査は通っていたので、
      // **実際の入れ子（`Expanded` + 右端の設定）**を再現して切り分ける。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 375,
              child: Row(
                children: [
                  Expanded(
                    child: ScrollingIconRow(
                      actions: actions(11),
                      controller: controller,
                    ),
                  ),
                  // 設定の代わり（幅だけ合わせる）。
                  const SizedBox(width: 155, height: 40),
                ],
              ),
            ),
          ),
        ),
      );

      expect(controller.offset, 0);
      await tester.drag(
        visible('a1'),
        const Offset(-120, 0),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();

      expect(
        controller.offset,
        greaterThan(0),
        reason: '⚠⚠ 入れ子で動かないなら、原因は部品ではなく画面側の組み方',
      );
    });

    testWidgets('⚠ 設定の側を引いても何も起きない（スクロールするのはアイコン列だけ）', (tester) async {
      // ⚠⚠ **これが実機の報告の正体でありうる。**設定は幅の 4 割を占めるので、
      // そこを引いても列は動かない。⚠ **仕様としては正しい**（設定が流れると
      // 送る前に確かめられなくなる）が、**触れる場所が狭い**という体験の問題は残る。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 375,
              child: Row(
                children: [
                  Expanded(
                    child: ScrollingIconRow(
                      actions: actions(11),
                      controller: controller,
                    ),
                  ),
                  const SizedBox(
                    width: 155,
                    height: 40,
                    child: ColoredBox(color: Color(0xFF222222)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.drag(
        find.byType(ColoredBox).last,
        const Offset(-120, 0),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();

      expect(controller.offset, 0);
    });

    testWidgets('⚠ 押せない操作は流す形でも押せない（送信中）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: ScrollingIconRow(
                controller: controller,
                actions: [
                  for (var i = 0; i < 3; i++)
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

      expect(tester.widget<IconButton>(visible('a0')).onPressed, isNull);
    });
  });
}
