import 'package:flutter_test/flutter_test.dart';

import 'support/provider_graph.dart';

/// #1097: 「現在のアカウント」に依存する provider が `dependencies:` を宣言している
/// ことの網羅検査。
///
/// デッキ（#720）フェーズ 2 は、カラムを `ProviderScope` で包んで
/// `currentAccountProvider` を上書きする（案 S・`docs/deck-ui-plan.md` 1-7）。
/// **宣言の無い provider は上書きに追随せず、ルートの「現在のアカウント」で動く。**
/// アカウント B のカラムで、アカウント A として投稿やお気に入りが外に出る（B-2）。
///
/// ⚠ Riverpod 2.6.1 は宣言漏れを debug で AssertionError にする
/// （`deck_scope_spike_test` 3）が、**2 つの穴がある**:
///
/// 1. **release では assert が消える**（同 3-b）
/// 2. ⚠⚠ **`ref.read` でしか読まない Notifier は依存として記録されない**ので、
///    debug でも assert が出ない。`loadMore()` の中の `ref.read(currentAdapterProvider)`
///    は、provider がルートに居ればルートのアダプタを黙って返す
///
/// → だから `watch` / `read` を区別せず、**ソースの参照そのもの**で見る。
///
/// ⚠ 規則は閉包で見る。`currentAccountProvider` を直接読まなくても、読む provider を
/// 読むなら同じく宣言が要る（例: `listsProvider` を読む `selectedListProvider`）。
///
/// ⚠ 拾えないもの（`ref` を関数引数で受け取るヘルパの中）は `provider_graph.dart`
/// の冒頭 doc を参照。
void main() {
  const roots = {'currentAccountProvider'};

  /// **意図的にルートスコープ専用**にする provider と理由。
  ///
  /// ここに入れると宣言を求めない代わりに、**カラムの中から読んでもルートの
  /// 「現在のアカウント」で動く。**アプリ全体で 1 つであるべきものだけを入れる。
  const rootOnly = <String, String>{
    'desktopNotificationDispatcherProvider':
        'デスクトップ通知の配送はアプリ全体で 1 つ。カラムごとに複製すると同じ通知が'
        '重複して出る。「現在のアカウントか」の比較もアプリの現在のアカウントが正しい',
  };

  group('実際のソース', () {
    final graph = buildProviderGraphFromDirectory('lib');

    test('探索が空振りしていない', () {
      // provider の定義を拾えているか。書式が変わって 0 件になると素通りする。
      expect(graph.nodes.length, greaterThan(100));
      for (final name in [
        'currentAccountProvider',
        'currentAdapterProvider',
        'timelineProvider',
        'hashtagTimelineProvider',
        'desktopNotificationDispatcherProvider',
      ]) {
        expect(graph.nodes, contains(name), reason: '$name を拾えていない');
      }
      // Notifier クラス本体（`TimelineNotifier.new`）の中の参照を拾えているか。
      expect(
        graph.nodes['timelineProvider']!.references,
        contains('currentAccountProvider'),
        reason: 'Notifier の本体を読めていない',
      );
      // `(ref) => Foo(ref)` のサービスクラスの中の参照を拾えているか。
      expect(
        graph.nodes['desktopNotificationDispatcherProvider']!.references,
        contains('currentAccountProvider'),
        reason: 'ref を受け取るクラスの本体を読めていない',
      );
      // 画面ウィジェットは provider の依存に数えない（ルーター定義の誤検出）。
      expect(
        graph.nodes['routerProvider']?.references ?? const <String>{},
        isNot(contains('_draftsProvider')),
      );
    });

    test('ルート専用の指定は、実在し、かつ閉包に入るものだけ（古い除外を残さない）', () {
      final scoped = graph.scopedClosure(roots);
      for (final name in rootOnly.keys) {
        expect(graph.nodes, contains(name), reason: '$name は存在しない');
        expect(scoped, contains(name), reason: '$name は現在のアカウントに依存しておらず、除外は不要');
      }
    });

    test('⚠⚠ 現在のアカウントに依存する provider は dependencies: を宣言している (#1095)', () {
      final missing = graph.missingDependencies(
        roots,
        rootOnly: rootOnly.keys.toSet(),
      );
      final report = [
        for (final e in missing.entries)
          '${graph.nodes[e.key]!.file}:${graph.nodes[e.key]!.line}'
              '-${graph.nodes[e.key]!.endLine} '
              '${e.key} に足りない: ${e.value.join(', ')}',
      ];
      // ⚠ expect(report, isEmpty) だと長いリストが途中で省略される。全件出す。
      if (report.isNotEmpty) {
        fail(
          'カラムのスコープ上書きに追随しない provider が ${report.length} 件ある。'
          'dependencies: に足すか、アプリ全体で 1 つであるべきなら rootOnly へ'
          '理由つきで足すこと:\n${report.join('\n')}',
        );
      }
    });
  });

  group('判定ロジック（合成ソース）', () {
    Map<String, Set<String>> missingOf(String source) =>
        buildProviderGraph({'a.dart': source}).missingDependencies(roots);

    const base = '''
final currentAccountProvider = Provider<Account?>((ref) => null);
''';

    test('直接 watch して宣言が無ければ当たる', () {
      expect(
        missingOf('''
$base
final adapterProvider = Provider((ref) => ref.watch(currentAccountProvider));
'''),
        {
          'adapterProvider': {'currentAccountProvider'},
        },
      );
    });

    test('宣言していれば当たらない', () {
      expect(
        missingOf('''
$base
final adapterProvider = Provider(
  (ref) => ref.watch(currentAccountProvider),
  dependencies: [currentAccountProvider],
);
'''),
        isEmpty,
      );
    });

    test('⚠ 間接に依存する provider も当たる（閉包）', () {
      expect(
        missingOf('''
$base
final adapterProvider = Provider(
  (ref) => ref.watch(currentAccountProvider),
  dependencies: [currentAccountProvider],
);
final listsProvider = FutureProvider((ref) async => ref.watch(adapterProvider));
'''),
        {
          'listsProvider': {'adapterProvider'},
        },
      );
    });

    test('⚠⚠ Notifier の中で ref.read しているだけでも当たる', () {
      expect(
        missingOf('''
$base
class FooNotifier extends Notifier<int> {
  int build() => 0;
  void load() => ref.read(currentAccountProvider);
}
final fooProvider = NotifierProvider<FooNotifier, int>(FooNotifier.new);
'''),
        {
          'fooProvider': {'currentAccountProvider'},
        },
      );
    });

    test('ref を受け取るサービスクラスの中の参照も当たる', () {
      expect(
        missingOf('''
$base
class Service {
  Service(this._ref);
  final Ref _ref;
  void run() => _ref.read(currentAccountProvider);
}
final serviceProvider = Provider((ref) => Service(ref));
'''),
        {
          'serviceProvider': {'currentAccountProvider'},
        },
      );
    });

    test('Ref を引数に取る関数の中の参照も当たる（Notifier から呼ぶ形）', () {
      expect(
        missingOf('''
$base
Future<void> _toggle(
  Ref ref,
  String id,
) async {
  ref.read(currentAccountProvider);
}
class FooNotifier extends Notifier<int> {
  int build() => 0;
  Future<void> toggle() => _toggle(ref, 'x');
}
final fooProvider = NotifierProvider<FooNotifier, int>(FooNotifier.new);
'''),
        {
          'fooProvider': {'currentAccountProvider'},
        },
      );
    });

    test('extension on Ref のメンバー経由の参照も当たる', () {
      expect(
        missingOf('''
$base
extension AccountOnRef on Ref {
  Account? get accountForReport {
    return read(currentAccountProvider);
  }
}
final fooProvider = FutureProvider((ref) async => ref.accountForReport);
'''),
        {
          'fooProvider': {'currentAccountProvider'},
        },
      );
    });

    test('⚠ extension の本体中の呼び出し名（read）で、無関係な ref.read を誤検出しない', () {
      expect(
        missingOf('''
$base
extension AccountOnRef on Ref {
  Account? get accountForReport {
    return read(currentAccountProvider);
  }
}
final otherProvider = Provider((ref) => 1);
final barProvider = Provider((ref) => ref.read(otherProvider));
'''),
        isEmpty,
      );
    });

    test('コメントや文字列に名前が出てくるだけなら当たらない', () {
      expect(
        missingOf('''
$base
// currentAccountProvider は読まない
final labelProvider = Provider((ref) => 'currentAccountProvider');
'''),
        isEmpty,
      );
    });

    test('名前で参照するだけの画面ウィジェットの中身は数えない', () {
      expect(
        missingOf('''
$base
class DraftsScreen extends ConsumerWidget {
  Widget build(context, ref) => Text(ref.watch(currentAccountProvider));
}
final routerProvider = Provider((ref) => GoRoute(builder: (_, _) => DraftsScreen()));
'''),
        isEmpty,
      );
    });

    test('宣言しているが一部足りなければ、足りない分だけ当たる', () {
      expect(
        missingOf('''
$base
final adapterProvider = Provider(
  (ref) => ref.watch(currentAccountProvider),
  dependencies: [currentAccountProvider],
);
final bothProvider = Provider(
  (ref) => [ref.watch(currentAccountProvider), ref.watch(adapterProvider)],
  dependencies: [currentAccountProvider],
);
'''),
        {
          'bothProvider': {'adapterProvider'},
        },
      );
    });
  });
}
