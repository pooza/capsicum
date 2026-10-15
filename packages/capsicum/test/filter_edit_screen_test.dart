import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/filter_edit_screen.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1047: フィルターの編集画面が組み立てる中身。
class _FakeAdapter extends Mock
    implements DecentralizedBackendAdapter, FilterSupport {
  FilterDraft? created;
  ({String id, FilterDraft draft})? updated;
  String? deleted;

  @override
  String get host => 'mstdn.example';

  @override
  Future<ServerFilter> createFilter(FilterDraft draft) async {
    created = draft;
    return ServerFilter(
      id: 'new',
      title: draft.title,
      contexts: draft.contexts,
      action: draft.action,
    );
  }

  @override
  Future<ServerFilter> updateFilter(String id, FilterDraft draft) async {
    updated = (id: id, draft: draft);
    return ServerFilter(
      id: id,
      title: draft.title,
      contexts: draft.contexts,
      action: draft.action,
    );
  }

  @override
  Future<void> deleteFilter(String id) async => deleted = id;
}

const _existing = ServerFilter(
  id: '12',
  title: 'ネタバレ',
  contexts: {FilterContext.home},
  action: FilterAction.hide,
  keywords: [
    FilterKeyword(id: '3', keyword: 'ダイ'),
    FilterKeyword(id: '4', keyword: 'ポップ'),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  _FakeAdapter adapter, {
  ServerFilter? filter,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [currentAdapterProvider.overrideWithValue(adapter)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<bool>(
                  builder: (_) => FilterEditScreen(filter: filter),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('作成: 名前とキーワードを入れて保存すると、既定の適用先で作る', (tester) async {
    final adapter = _FakeAdapter();
    await _pump(tester, adapter);

    await tester.enterText(find.widgetWithText(TextField, '名前'), '実況');
    await tester.enterText(find.widgetWithText(TextField, 'キーワード'), 'ネタバレ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final draft = adapter.created!;
    expect(draft.title, '実況');
    expect(draft.keywords.single.keyword, 'ネタバレ');
    expect(draft.keywords.single.id, isNull);
    expect(draft.action, FilterAction.warn);
    expect(draft.contexts, {
      FilterContext.home,
      FilterContext.notifications,
      FilterContext.public,
      FilterContext.thread,
    });
    expect(draft.expiry, isA<NoFilterExpiry>());
    expect(find.byType(FilterEditScreen), findsNothing, reason: '保存したら閉じる');
  });

  testWidgets('⚠ 名前が空なら保存しない', (tester) async {
    final adapter = _FakeAdapter();
    await _pump(tester, adapter);

    await tester.enterText(find.widgetWithText(TextField, 'キーワード'), 'ネタバレ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(adapter.created, isNull);
    expect(find.text('名前を入れてください'), findsOneWidget);
  });

  testWidgets('⚠⚠ 編集: 外したキーワードと空にしたキーワードは削除として送る', (tester) async {
    final adapter = _FakeAdapter();
    await _pump(tester, adapter, filter: _existing);

    // 1 つ目（ダイ）を外す、2 つ目（ポップ）を空にする、新しく 1 つ足す。
    await tester.tap(find.byTooltip('このキーワードを外す').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'ポップ'), '');
    await tester.tap(find.text('キーワードを追加'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'キーワード').last, 'アバン');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final (:id, :draft) = adapter.updated!;
    expect(id, '12');
    expect(draft.removedKeywordIds, unorderedEquals(['3', '4']));
    expect(draft.keywords.map((k) => (k.id, k.keyword)), [(null, 'アバン')]);
    expect(draft.action, FilterAction.hide, reason: '触っていない項目は元のまま');
    expect(draft.contexts, {FilterContext.home});
  });

  testWidgets('⚠ 編集: 期限の無いフィルターは「無期限」のまま送る', (tester) async {
    final adapter = _FakeAdapter();
    await _pump(tester, adapter, filter: _existing);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(adapter.updated!.draft.expiry, isA<NoFilterExpiry>());
  });

  testWidgets('⚠⚠ 編集: 期限のあるフィルターは既定で「変えない」', (tester) async {
    final adapter = _FakeAdapter();
    final withExpiry = ServerFilter(
      id: '12',
      title: 'ネタバレ',
      contexts: const {FilterContext.home},
      action: FilterAction.warn,
      expiresAt: DateTime.utc(2026, 10, 20),
      keywords: const [FilterKeyword(id: '3', keyword: 'ダイ')],
    );
    await _pump(tester, adapter, filter: withExpiry);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      adapter.updated!.draft.expiry,
      isA<KeepFilterExpiry>(),
      reason: '既定で「無期限」を送ると、編集のたびに期限が消える',
    );
  });

  testWidgets('削除は確認してから消す', (tester) async {
    final adapter = _FakeAdapter();
    await _pump(tester, adapter, filter: _existing);

    await tester.tap(find.byTooltip('削除'));
    await tester.pumpAndSettle();
    expect(adapter.deleted, isNull, reason: '確認の前に消さない');
    await tester.tap(find.widgetWithText(TextButton, '削除'));
    await tester.pumpAndSettle();

    expect(adapter.deleted, '12');
  });
}
