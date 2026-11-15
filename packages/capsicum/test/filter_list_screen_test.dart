import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/filter_list_screen.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1047: フィルターの一覧。
class _FakeAdapter extends Mock
    implements DecentralizedBackendAdapter, FilterSupport {
  _FakeAdapter(this.filters, {this.error});

  final List<ServerFilter> filters;

  /// 非 null なら getFilters はこれを投げる。
  final Object? error;

  @override
  String get host => 'mstdn.example';

  @override
  Future<List<ServerFilter>> getFilters() async {
    if (error != null) throw error!;
    return filters;
  }
}

Future<void> _pump(WidgetTester tester, _FakeAdapter adapter) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [currentAdapterProvider.overrideWithValue(adapter)],
      child: const MaterialApp(home: FilterListScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ⚠ 現在のアカウントが取れない（null）ときも読み込みを始める。以前は「前回の
  // アカウント」の初期値も null だったので、変化なしと見て一度も読まなかった。
  testWidgets('⚠ 一覧を読み込んで、名前と動作を出す', (tester) async {
    await _pump(
      tester,
      _FakeAdapter([
        ServerFilter(
          id: '1',
          title: 'ネタバレ',
          contexts: const {FilterContext.home, FilterContext.notifications},
          action: FilterAction.hide,
          expiresAt: DateTime.utc(2020),
          keywords: const [FilterKeyword(keyword: 'ダイ')],
        ),
      ]),
    );

    expect(find.text('ネタバレ'), findsOneWidget);
    expect(find.textContaining('完全に隠す'), findsOneWidget);
    expect(find.textContaining('ホームおよびリスト・通知'), findsOneWidget);
    expect(find.textContaining('期限切れ'), findsOneWidget);
  });

  testWidgets('空なら案内を出す', (tester) async {
    await _pump(tester, _FakeAdapter(const []));
    expect(find.text('フィルターはありません'), findsOneWidget);
  });

  // #1287: Akkoma などは v2 のフィルターの口が無い。失敗ではないので
  // 「読み込みに失敗しました」にせず、新規作成も出さない。
  testWidgets('⚠ 口が無いサーバーでは使えない旨を出し、新規作成を出さない', (tester) async {
    await _pump(
      tester,
      _FakeAdapter(const [], error: const FiltersUnavailable()),
    );
    expect(find.text('このサーバーではフィルターを使えません'), findsOneWidget);
    expect(find.text('読み込みに失敗しました'), findsNothing);
    expect(find.byTooltip('新規作成'), findsNothing);
  });

  testWidgets('⚠ ほかの失敗は従来どおり「読み込みに失敗しました」', (tester) async {
    await _pump(tester, _FakeAdapter(const [], error: Exception('x')));
    expect(find.text('読み込みに失敗しました'), findsOneWidget);
    expect(find.text('このサーバーではフィルターを使えません'), findsNothing);
    expect(find.byTooltip('新規作成'), findsOneWidget);
  });
}
