import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
import 'package:capsicum/src/ui/widget/deck_column_strip.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1241: 見たいカラムへ 1 回で飛べる帯。
///
/// 狭幅のデッキはカラムが 1 本ずつしか見えないので、N 本目へ行くには N-1 回
/// スワイプするか、カラム編集のシートを開いて選ぶ（2 タップ）しかなかった。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

class _Capabilities extends Mock implements AdapterCapabilities {}

/// コマのツールチップ（見出しと同じラベル）が種別の判定に読む。
_Adapter _adapter() {
  final capabilities = _Capabilities();
  when(
    () => capabilities.supportedTimelines,
  ).thenReturn({TimelineType.home, TimelineType.local, TimelineType.social});
  final adapter = _Adapter();
  when(() => adapter.capabilities).thenReturn(capabilities);
  return adapter;
}

final _account = Account(
  key: const AccountKey(
    type: BackendType.misskey,
    host: 'misskey.example',
    username: 'me',
  ),
  adapter: _adapter(),
  user: const User(id: 'me', username: 'me'),
  userSecret: const UserSecret(accessToken: 'token'),
);

class _TestAccountNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_account], current: _account);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpDeck(
    WidgetTester tester, {
    required Size size,
    List<String> columnIds = const ['a', 'b', 'c', 'd'],
    List<String> locked = const [],
    bool stripOnWide = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': [
        // ⚠ タグは並び順で付ける（コマのツールチップ＝見出しで n 本目を引く）。
        for (final (i, id) in columnIds.indexed)
          '$id|misskey://me@misskey.example|hashtag:tag${i + 1}',
      ],
      'deck_locked_columns': locked,
      'deck_strip_on_wide': stripOnWide,
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(_TestAccountNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DeckScreen(
            columnBuilder: (column) => ColoredBox(
              key: ValueKey('stub-${column.id}'),
              color: const Color(0xFF202020),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  const narrow = Size(375, 700);

  double left(WidgetTester tester, String id) =>
      tester.getTopLeft(find.byKey(ValueKey('stub-$id'))).dx;

  // #1404: ツールチップはカラムの見出しと同じ「タブ名 · 表示名」。
  Finder item(int number) => find.byTooltip('#tag$number · me');

  testWidgets('狭幅では帯が出て、カラムの数だけコマが並ぶ', (tester) async {
    await pumpDeck(tester, size: narrow);

    expect(find.byType(DeckColumnStrip), findsOneWidget);
    for (var n = 1; n <= 4; n++) {
      expect(item(n), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('コマのツールチップは、カラムの見出しと同じ「タブ名 · 表示名」', (tester) async {
    await pumpDeck(tester, size: narrow);

    expect(find.byTooltip('#tag1 · me'), findsOneWidget);
    // 以前の「カラム N（@user@host）」の形は使わない。
    expect(find.byTooltip('カラム 1（@me@misskey.example）'), findsNothing);
  });

  testWidgets('⚠⚠ コマを押すと、1 回でそのカラムへ移る', (tester) async {
    final container = await pumpDeck(tester, size: narrow);
    expect(left(tester, 'a'), closeTo(0, 1), reason: '前提: 先頭から始まる');

    await tester.tap(item(4));
    await tester.pumpAndSettle();

    expect(left(tester, 'd'), closeTo(0, 1), reason: 'スワイプ 3 回ぶんを 1 回で');
    // ⚠ 宛先（検索・通知・簡易投稿バー）も移る。
    expect(container.read(deckFocusProvider).columnId, 'd');
  });

  testWidgets('いま見ているカラムのコマに印が付く（スワイプで移っても追従する）', (tester) async {
    // 見た目（下線の色）ではなく、読み上げに渡る「選択中」で見る。
    final handle = tester.ensureSemantics();
    await pumpDeck(tester, size: narrow);

    bool marked(int number) =>
        tester
            .getSemantics(
              find.descendant(of: item(number), matching: find.byType(InkWell)),
            )
            .flagsCollection
            .isSelected
            .toBoolOrNull() ??
        false;

    expect(marked(1), isTrue);
    expect(marked(2), isFalse);

    // 横へスワイプして 2 本目へ。
    await tester.drag(
      find.byKey(const ValueKey('stub-a')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();

    expect(marked(2), isTrue, reason: 'スワイプで移っても印が追従する');
    expect(marked(1), isFalse);
    handle.dispose();
  });

  testWidgets('⚠ 広幅では出さない（カラムが並んで見えている）', (tester) async {
    await pumpDeck(tester, size: const Size(1200, 700));

    expect(find.byType(DeckColumnStrip), findsNothing);
  });

  testWidgets('カラムが 1 本なら出さない（飛ぶ先が無い）', (tester) async {
    await pumpDeck(tester, size: narrow, columnIds: const ['a']);

    expect(find.byType(DeckColumnStrip), findsNothing);
  });

  testWidgets('カラムが画面より多くても溢れず、押せば端まで行ける', (tester) async {
    final ids = [for (var i = 0; i < 12; i++) 'c$i'];
    final container = await pumpDeck(tester, size: narrow, columnIds: ids);
    expect(tester.takeException(), isNull);

    // 12 本目のコマは最初は画面の外。帯を流して押す。
    await tester.scrollUntilVisible(
      item(12),
      200,
      scrollable: find.descendant(
        of: find.byType(DeckColumnStrip),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(item(12));
    await tester.pumpAndSettle();

    expect(container.read(deckFocusProvider).columnId, 'c11');
    expect(left(tester, 'c11'), closeTo(0, 1));
  });

  // #1405: 帯の右端に「ロックしていないカラムを閉じる」を置く。
  group('ロックしていないカラムを閉じる (#1405)', () {
    final button = find.byKey(const ValueKey('deck-strip-close-unlocked'));

    IconButton iconButton(WidgetTester tester) =>
        tester.widget<IconButton>(button);

    testWidgets('⚠ ロックしたカラムが無ければ、隠さず押せなくする（理由を添える）', (tester) async {
      await pumpDeck(tester, size: narrow);

      expect(button, findsOneWidget);
      expect(iconButton(tester).onPressed, isNull);
      expect(
        find.byTooltip('ロックしていないカラムを閉じる（ロックしたカラムがあると使えます）'),
        findsOneWidget,
      );
    });

    testWidgets('⚠⚠ 押すと 1 回でロックしていないカラムが閉じ、ロック中へフォーカスが移る', (tester) async {
      final container = await pumpDeck(tester, size: narrow, locked: ['a']);
      // 先にロックしていないカラムへ移っておく。
      await tester.tap(item(3));
      await tester.pumpAndSettle();
      expect(container.read(deckFocusProvider).columnId, 'c');
      expect(find.byTooltip('ロックしていないカラムを閉じる'), findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(
        [for (final c in container.read(deckColumnsProvider)) c.id],
        ['a'],
      );
      expect(container.read(deckFocusProvider).columnId, 'a');
      expect(tester.takeException(), isNull);
    });

    testWidgets('⚠ 帯の右端に固定する（コマと一緒に流れない）', (tester) async {
      final ids = [for (var i = 0; i < 12; i++) 'c$i'];
      await pumpDeck(tester, size: narrow, columnIds: ids, locked: ['c0']);
      final strip = tester.getRect(find.byType(DeckColumnStrip));
      final before = tester.getRect(button);
      expect(before.right, closeTo(strip.right - 4, 1), reason: '右端にある');

      // 帯を流しても動かない。
      await tester.drag(
        find.descendant(
          of: find.byType(DeckColumnStrip),
          matching: find.byType(Scrollable),
        ),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(button), before);
    });

    testWidgets('⚠ コマはボタンの下に潜らない（いま見ているコマが見える位置へ寄る）', (tester) async {
      final ids = [for (var i = 0; i < 12; i++) 'c$i'];
      await pumpDeck(tester, size: narrow, columnIds: ids);

      // 押した先のコマ（列の後ろのほう）が、ボタンより左に収まっている。
      await tester.scrollUntilVisible(
        item(11),
        200,
        scrollable: find.descendant(
          of: find.byType(DeckColumnStrip),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(item(11));
      await tester.pumpAndSettle();
      final focused = tester.getRect(item(11));
      expect(focused.right, lessThanOrEqualTo(tester.getRect(button).left));
      expect(focused.left, greaterThanOrEqualTo(0));
    });
  });

  // #1404: 広い幅でも帯を出す設定（既定 OFF）。
  group('広い幅でも帯を出す (#1404)', () {
    const wide = Size(1200, 700);
    final ids = [for (var i = 0; i < 8; i++) 'w$i'];

    double opacityOf(WidgetTester tester, int number) => tester
        .widget<Opacity>(
          find.descendant(of: item(number), matching: find.byType(Opacity)),
        )
        .opacity;

    bool marked(WidgetTester tester, int number) =>
        tester
            .getSemantics(
              find.descendant(of: item(number), matching: find.byType(InkWell)),
            )
            .flagsCollection
            .isSelected
            .toBoolOrNull() ??
        false;

    testWidgets('⚠ 既定（OFF）では広い幅に出さない（今の見た目を変えない）', (tester) async {
      await pumpDeck(tester, size: wide, columnIds: ids);

      expect(find.byType(DeckColumnStrip), findsNothing);
    });

    testWidgets('ON なら広い幅でも出る', (tester) async {
      await pumpDeck(tester, size: wide, columnIds: ids, stripOnWide: true);

      expect(find.byType(DeckColumnStrip), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('⚠ 1 本なら ON でも出さない（飛ぶ先が無い）', (tester) async {
      await pumpDeck(
        tester,
        size: wide,
        columnIds: const ['a'],
        stripOnWide: true,
      );

      expect(find.byType(DeckColumnStrip), findsNothing);
    });

    testWidgets('⚠⚠ 画面に見えているカラムのコマは沈ませない。下線はフォーカス中だけ', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpDeck(tester, size: wide, columnIds: ids, stripOnWide: true);

      // 先頭の 2 本は見えている（1200 幅に 8 本は収まらない）。
      expect(opacityOf(tester, 1), 1);
      expect(opacityOf(tester, 2), 1);
      // 末尾は見えていないので沈む。
      expect(opacityOf(tester, 8), lessThan(1));
      // 印（選択中）はフォーカス中の 1 本だけ。
      expect(marked(tester, 1), isTrue);
      expect(marked(tester, 2), isFalse);
      handle.dispose();
    });

    testWidgets('⚠ 横に流すと、沈ませないコマも追従する', (tester) async {
      await pumpDeck(tester, size: wide, columnIds: ids, stripOnWide: true);
      expect(opacityOf(tester, 8), lessThan(1), reason: '前提: 末尾は見えていない');

      // コマを押して末尾まで送る。
      await tester.tap(item(8));
      await tester.pumpAndSettle();

      expect(opacityOf(tester, 8), 1);
      expect(opacityOf(tester, 1), lessThan(1), reason: '先頭は画面の外へ出た');
      expect(tester.takeException(), isNull);
    });
  });
}
