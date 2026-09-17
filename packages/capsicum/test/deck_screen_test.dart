import 'package:capsicum/src/model/deck_column.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1092: デッキ画面のカラムコンテナ。
///
/// カラムの中身は差し替え口（`columnBuilder`）で軽いものにして、**コンテナの
/// 振る舞いだけ**を見る（`PostTile` の依存一式を用意しないため）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 各カラムの `initState` が何回走ったか（カラム id → 回数）。
  final initCounts = <String, int>{};

  setUp(initCounts.clear);

  Future<void> pumpDeck(
    WidgetTester tester, {
    required Size size,
    required List<String> columnIds,
  }) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': [
        for (final id in columnIds)
          '$id|misskey://me@misskey.example|hashtag:$id',
      ],
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DeckScreen(
            columnBuilder: (column) => _StubColumn(
              key: ValueKey('stub-${column.id}'),
              column: column,
              initCounts: initCounts,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double columnWidthOf(WidgetTester tester, String id) =>
      tester.getSize(find.byKey(ValueKey('stub-$id'))).width;

  /// カラムを横に並べるスクロール。⚠ ウィジェットの型（`SingleChildScrollView`
  /// 等）では探さない。コンテナの作りを変えたとき、**検査が型の探索で落ちて、
  /// 見たいこと（カラムが生きているか）を見ないまま赤になる**のを避ける。
  final horizontalScroller = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
  );

  double horizontalOffset(WidgetTester tester) =>
      tester.state<ScrollableState>(horizontalScroller).position.pixels;

  testWidgets('カラムが無ければその旨を出す', (tester) async {
    await pumpDeck(tester, size: const Size(800, 600), columnIds: const []);
    expect(find.text('カラムがありません'), findsOneWidget);
  });

  testWidgets('800px では 2 本が画面に入り、各 400px', (tester) async {
    await pumpDeck(
      tester,
      size: const Size(800, 600),
      columnIds: const ['a', 'b', 'c'],
    );
    expect(columnWidthOf(tester, 'a'), 400);
    expect(columnWidthOf(tester, 'c'), 400);
  });

  testWidgets('狭い幅では 1 カラムで全幅になり、カラムの境界で止まる（ページャ）', (tester) async {
    await pumpDeck(
      tester,
      size: const Size(390, 700),
      columnIds: const ['a', 'b', 'c'],
    );
    expect(columnWidthOf(tester, 'a'), 390);

    // 半分弱しか動かさなければ元のカラムへ戻る。
    await tester.drag(horizontalScroller, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(horizontalOffset(tester), 0);

    // 半分を超えて動かせば次のカラムで止まる。
    await tester.drag(horizontalScroller, const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(horizontalOffset(tester), 390);
  });

  testWidgets('⚠⚠ 横に 1 つ動いて戻っても、元のカラムは作り直されず縦のスクロール位置も残る', (tester) async {
    await pumpDeck(
      tester,
      size: const Size(390, 700),
      columnIds: const ['a', 'b', 'c'],
    );

    // カラム a を縦にスクロールしておく。
    await tester.drag(
      find.byKey(const ValueKey('list-a')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    final offsetBefore = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('list-a')),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    expect(offsetBefore, greaterThan(0), reason: '前提: 縦に動いている');

    // 横に 2 つ進んで戻る。
    await tester.drag(horizontalScroller, const Offset(-250, 0));
    await tester.pumpAndSettle();
    await tester.drag(horizontalScroller, const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(horizontalOffset(tester), 780, reason: '前提: カラム c まで来ている');
    await tester.drag(horizontalScroller, const Offset(250, 0));
    await tester.pumpAndSettle();
    await tester.drag(horizontalScroller, const Offset(250, 0));
    await tester.pumpAndSettle();
    expect(horizontalOffset(tester), 0);

    expect(initCounts, {
      'a': 1,
      'b': 1,
      'c': 1,
    }, reason: '画面外へ出たカラムを捨てて作り直していない');
    final offsetAfter = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('list-a')),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    expect(offsetAfter, offsetBefore);
  });
}

/// 縦に長いリストを持つだけのカラム。`initState` の回数を数える。
class _StubColumn extends StatefulWidget {
  const _StubColumn({
    super.key,
    required this.column,
    required this.initCounts,
  });

  final DeckColumn column;
  final Map<String, int> initCounts;

  @override
  State<_StubColumn> createState() => _StubColumnState();
}

class _StubColumnState extends State<_StubColumn> {
  @override
  void initState() {
    super.initState();
    widget.initCounts.update(widget.column.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: ValueKey('list-${widget.column.id}'),
    itemCount: 100,
    itemBuilder: (_, i) =>
        SizedBox(height: 40, child: Text('${widget.column.id}-$i')),
  );
}
