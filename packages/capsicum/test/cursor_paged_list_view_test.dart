import 'dart:async';

import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/widget/cursor_paged_list_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// `CursorPagedListView` の振る舞い（v1.64 のリリース前レビュー）。
///
/// ソース検査（`list_screen_error_state_test`）は「その書き方をしているか」
/// しか見ないので、ここは実際に動かして固定する。
void main() {
  Widget host(CursorPageFetcher<String> fetcher) => ProviderScope(
    overrides: [currentAccountProvider.overrideWith((ref) => null)],
    child: MaterialApp(
      home: Scaffold(
        body: CursorPagedListView<String>(
          fetcher: fetcher,
          itemBuilder: (context, item) =>
              SizedBox(height: 60, child: Text(item)),
          emptyMessage: '空',
          debugLabel: 'test',
          tagKey: 'test.op',
        ),
      ),
    ),
  );

  List<String> page(String prefix) => [
    for (var i = 0; i < 30; i++) '$prefix$i',
  ];

  Future<void> scrollToEnd(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, -5000));
    await tester.pumpAndSettle();
  }

  testWidgets('⚠⚠ 追加読み込みが失敗したら、スクロールしても自動では取り直さない', (tester) async {
    var moreCalls = 0;
    await tester.pumpWidget(
      host((cursor) async {
        if (cursor == null) return (items: page('a'), nextCursor: 'c1');
        moreCalls++;
        throw Exception('offline');
      }),
    );
    await tester.pumpAndSettle();

    await scrollToEnd(tester);
    expect(moreCalls, 1);
    expect(find.text('続きを読み込めませんでした'), findsOneWidget);

    // 失敗後に何度スクロール通知が来ても、取りに行かない（Sentry を連打しない）。
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    await scrollToEnd(tester);
    await scrollToEnd(tester);
    expect(moreCalls, 1, reason: 'スクロールのたびに再取得→即失敗→報告を繰り返していた');

    // 「再試行」を押したときだけ取り直す。
    await tester.tap(find.text('再試行'));
    await tester.pumpAndSettle();
    expect(moreCalls, 2);
  });

  testWidgets('追加読み込みが成功すれば末尾に連結する', (tester) async {
    await tester.pumpWidget(
      host((cursor) async {
        if (cursor == null) return (items: page('a'), nextCursor: 'c1');
        return (items: page('b'), nextCursor: null);
      }),
    );
    await tester.pumpAndSettle();
    await scrollToEnd(tester);
    // 連結で末尾が伸びるので、もう一度末尾へ送ってから見る。
    await scrollToEnd(tester);
    expect(find.text('b29'), findsOneWidget);
    expect(find.text('続きを読み込めませんでした'), findsNothing);
  });

  testWidgets('⚠⚠ 引っ張って更新の最中に始まった追加読み込み（古いカーソル）は捨てる', (tester) async {
    // 1 回目の load は即返す。2 回目（引っ張って更新）は Completer で止める。
    var loads = 0;
    // ⚠ **見えるかどうかで判定しない。**ListView は画面外を描かないので、
    // 連結されていても `find.text` が素通りした（歯の確認で踏んだ）。
    // どのカーソルで取りに来たかを記録して見る。
    final requested = <String>[];
    final refresh = Completer<({List<String> items, String? nextCursor})>();
    final stale = Completer<({List<String> items, String? nextCursor})>();
    await tester.pumpWidget(
      host((cursor) {
        if (cursor == null) {
          loads++;
          if (loads == 1) {
            return Future.value((items: page('a'), nextCursor: 'c1'));
          }
          return refresh.future;
        }
        requested.add(cursor);
        if (cursor == 'c1') return stale.future; // 古いカーソル
        return Future.value((items: page('z'), nextCursor: null));
      }),
    );
    await tester.pumpAndSettle();

    // 引っ張って更新（load を走らせ、1 ページ目が返る前で止める）。
    // Flutter 本体の RefreshIndicator のテストと同じ手順。
    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(loads, 2);

    // その間に末尾へ。load が世代を上げたあとなので、世代だけでは弾けない。
    await tester.drag(find.byType(ListView), const Offset(0, -5000));
    await tester.pump();
    expect(requested, ['c1'], reason: '⚠ 検査の前提: 更新の最中に古いカーソルで追加読み込みが始まっていること');

    // load が先に着く（新しい 1 ページ目・カーソルは d1 へ）。
    refresh.complete((items: page('n'), nextCursor: 'd1'));
    await tester.pump();
    // 古いカーソルで取った結果が後から着く。
    stale.complete((items: page('old'), nextCursor: 'c2'));
    await tester.pumpAndSettle();

    // ⚠ 既に末尾に居ると、ドラッグしても位置が変わらずスクロール通知が来ない。
    // いったん戻してから末尾へ送る。
    await tester.drag(find.byType(ListView), const Offset(0, 800));
    await tester.pumpAndSettle();
    await scrollToEnd(tester);
    expect(
      requested,
      ['c1', 'd1'],
      reason:
          '古いカーソルのページを採用すると、そのページのカーソル（c2）で続きを'
          '取りに行く＝新しい 1 ページ目に古いページが連結されている',
    );
  });
}
