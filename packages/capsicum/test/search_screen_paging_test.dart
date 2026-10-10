import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/search_screen.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1202: 検索結果の続きを読める。
///
/// ⚠ **1 ページで打ち切られてもエラーにならない。**「それだけしか無い」ように
/// 見えるので、続きの口が出ること・正しい offset で読むことを固定する。
///
/// ハッシュタグの検索（`#` 始まり）で見る。一覧が文字だけで組めて、notestock
/// への問い合わせも走らないため。
class _PagingAdapter extends Mock
    implements DecentralizedBackendAdapter, SearchSupport, SearchPagingSupport {
  _PagingAdapter({required this.first, this.more = const []});

  /// 1 ページ目に返すタグ。
  final List<String> first;

  /// 続きを読むたびに、先頭から 1 ページずつ返す。
  final List<List<String>> more;

  final List<({String query, SearchKind kind, int offset})> moreCalls = [];
  bool failMore = false;

  @override
  int get searchPageSize => 20;

  @override
  Future<SearchResults> search(String query) async =>
      SearchResults(hashtags: first);

  @override
  Future<SearchResults> searchMore(
    String query,
    SearchKind kind, {
    required int offset,
  }) async {
    moreCalls.add((query: query, kind: kind, offset: offset));
    if (failMore) throw Exception('boom');
    return SearchResults(hashtags: more[moreCalls.length - 1]);
  }
}

/// 続きの口を持たないバックエンド（いまの Misskey）。
class _PlainAdapter extends Mock
    implements DecentralizedBackendAdapter, SearchSupport {
  @override
  Future<SearchResults> search(String query) async =>
      SearchResults(hashtags: _tags(0, 20));
}

List<String> _tags(int from, int count) => [
  for (var i = from; i < from + count; i++) 'tag$i',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> search(
    WidgetTester tester,
    DecentralizedBackendAdapter adapter,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [currentAdapterProvider.overrideWithValue(adapter)],
        child: const MaterialApp(home: SearchScreen()),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), '#tag');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  final moreButton = find.widgetWithText(TextButton, 'もっと読む');

  // ⚠ **`find.byType(Scrollable).last` で取らない。**`Scaffold` は body を
  // AppBar より先に組むので、最後の Scrollable は入力欄のものになる。
  final listScrollable = find.descendant(
    of: find.byType(ListView),
    matching: find.byType(Scrollable),
  );

  Future<void> tapMore(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      moreButton,
      300,
      scrollable: listScrollable,
    );
    await tester.tap(moreButton);
    await tester.pumpAndSettle();
  }

  testWidgets('1 ページぶん返ってきたら続きの口が出て、押すと offset を付けて読む', (tester) async {
    final adapter = _PagingAdapter(first: _tags(0, 20), more: [_tags(20, 5)]);
    await search(tester, adapter);

    await tapMore(tester);

    expect(adapter.moreCalls, [
      (query: 'tag', kind: SearchKind.hashtags, offset: 20),
    ]);
    // 5 件は 1 ページに満たない ＝ 終端。口は消える。
    await tester.scrollUntilVisible(
      find.text('#tag24'),
      300,
      scrollable: listScrollable,
    );
    expect(find.text('#tag24'), findsOneWidget);
    expect(moreButton, findsNothing);
  });

  testWidgets('1 ページに満たなければ、続きの口を出さない', (tester) async {
    final adapter = _PagingAdapter(first: _tags(0, 19));
    await search(tester, adapter);

    await tester.scrollUntilVisible(
      find.text('#tag18'),
      300,
      scrollable: listScrollable,
    );
    expect(moreButton, findsNothing);
    expect(adapter.moreCalls, isEmpty);
  });

  testWidgets('⚠ offset は表示件数ではなく、サーバーから読んだ件数で進める', (tester) async {
    // 2 ページ目の 20 件のうち 3 件が 1 ページ目と重複している。表示は 37 件
    // だが、次に送る offset は 40。37 で送ると 3 件を読み直す。
    final adapter = _PagingAdapter(
      first: _tags(0, 20),
      more: [_tags(17, 20), _tags(40, 1)],
    );
    await search(tester, adapter);

    await tapMore(tester);
    await tapMore(tester);

    expect(adapter.moreCalls.map((c) => c.offset), [20, 40]);
    // 重複は 1 行にまとめる。
    await tester.scrollUntilVisible(
      find.text('#tag17'),
      -300,
      scrollable: listScrollable,
    );
    expect(find.text('#tag17'), findsOneWidget);
  });

  testWidgets('⚠ 続きの読み込みに失敗しても、口は残る（押し直せる）', (tester) async {
    final adapter = _PagingAdapter(first: _tags(0, 20), more: [_tags(20, 5)])
      ..failMore = true;
    await search(tester, adapter);

    await tapMore(tester);

    expect(find.text('続きを読み込めませんでした'), findsOneWidget);
    expect(moreButton, findsOneWidget);

    // スナックバーが下端の口に被さるので、消えるのを待ってから押し直す。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    adapter.failMore = false;
    await tapMore(tester);
    // ⚠ 失敗した回は offset を進めない。同じ位置から読み直す。
    expect(adapter.moreCalls.map((c) => c.offset), [20, 20]);
  });

  testWidgets('続きの口を持たないバックエンドでは、口を出さない', (tester) async {
    await search(tester, _PlainAdapter());

    await tester.scrollUntilVisible(
      find.text('#tag19'),
      300,
      scrollable: listScrollable,
    );
    expect(moreButton, findsNothing);
  });
}
