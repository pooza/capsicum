import 'package:capsicum/src/ui/util/provider_scope_carrier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// #1149: カラム（スコープ付きコンテナ）から全画面へ push したとき、開いた画面が
/// カラムのコンテナを読むこと。
final _accountName = Provider<String>((ref) => 'root');

Widget _app({required bool carry}) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const _Column()),
      GoRoute(
        path: '/compose',
        builder: (context, state) =>
            withExtraProviderScope(state.extra, const _Compose()),
      ),
    ],
  );
  return ProviderScope(
    child: _ColumnScope(
      carry: carry,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
}

/// ルートの `ProviderScope` の下に、カラム用のコンテナを 1 つだけ作る。
///
/// ⚠ 実物のデッキはカラムを `carryProviderScope` で包む。ここでは router 全体を
/// 包めないので、`_Column` の中で包む（[_ColumnScopeData] で受け渡す）。
class _ColumnScope extends ConsumerStatefulWidget {
  const _ColumnScope({required this.carry, required this.child});

  final bool carry;
  final Widget child;

  @override
  ConsumerState<_ColumnScope> createState() => _ColumnScopeState();
}

class _ColumnScopeState extends ConsumerState<_ColumnScope> {
  late final ProviderContainer _container = ProviderContainer(
    parent: ProviderScope.containerOf(context, listen: false),
    overrides: [_accountName.overrideWithValue('column-b')],
  );

  @override
  void dispose() {
    _container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ColumnScopeData(
    container: _container,
    carry: widget.carry,
    child: widget.child,
  );
}

class _ColumnScopeData extends InheritedWidget {
  const _ColumnScopeData({
    required this.container,
    required this.carry,
    required super.child,
  });

  final ProviderContainer container;
  final bool carry;

  @override
  bool updateShouldNotify(_ColumnScopeData oldWidget) => false;
}

class _Column extends StatelessWidget {
  const _Column();

  @override
  Widget build(BuildContext context) {
    final data = context
        .dependOnInheritedWidgetOfExactType<_ColumnScopeData>()!;
    return Scaffold(
      body: carryProviderScope(
        data.container,
        Builder(
          builder: (context) => Consumer(
            builder: (context, ref, _) => Column(
              children: [
                Text('column:${ref.watch(_accountName)}'),
                TextButton(
                  onPressed: () => context.push(
                    '/compose',
                    extra: data.carry
                        ? extraWithProviderScope(context, {'initialText': 'x'})
                        : {'initialText': 'x'},
                  ),
                  child: const Text('open'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Compose extends ConsumerWidget {
  const _Compose();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Scaffold(body: Text('compose:${ref.watch(_accountName)}'));
}

void main() {
  testWidgets('extraWithProviderScope で push するとカラムのアカウントで開く', (tester) async {
    await tester.pumpWidget(_app(carry: true));
    expect(find.text('column:column-b'), findsOneWidget);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('compose:column-b'), findsOneWidget);
  });

  testWidgets('⚠ 載せないとルートのアカウントで開く（この仕組みが要る理由）', (tester) async {
    // ⚠ これが column-b になったら go_router がスコープを持ち込むようになった
    // ということで、extraWithProviderScope 自体が要らなくなっている。
    await tester.pumpWidget(_app(carry: false));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('compose:root'), findsOneWidget);
  });

  test('スコープが載っていない extra はそのまま（起動時の共有インテント等）', () {
    const child = SizedBox();
    expect(withExtraProviderScope(null, child), same(child));
    expect(
      withExtraProviderScope(<String, dynamic>{'sharedText': 's'}, child),
      same(child),
    );
  });
}
