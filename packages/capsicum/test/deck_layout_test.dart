import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/util/deck_layout.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1092: デッキのカラム幅の割り付け。
///
/// 算法は参考実装（SubwayTooter `resizeColumnWidth()`）と同じで、下限だけ capsicum の
/// 375px にしている（`docs/deck-ui-plan.md` 未決事項 8）。
void main() {
  DeckLayout layoutOf(double width, {int columns = 10, double? min}) =>
      computeDeckLayout(
        availableWidth: width,
        columnCount: columns,
        minColumnWidth: min ?? minDeckColumnWidth,
      );

  group('設計書の表どおりに割り付ける', () {
    test('2 本入らない幅は 1 カラムで全幅（そのままページャ）', () {
      expect(
        layoutOf(374),
        const DeckLayout(visibleColumns: 1, columnWidth: 374),
      );
      expect(
        layoutOf(749),
        const DeckLayout(visibleColumns: 1, columnWidth: 749),
      );
    });

    test('750px で 2 カラム・各 375', () {
      expect(
        layoutOf(750),
        const DeckLayout(visibleColumns: 2, columnWidth: 375),
      );
    });

    test('800px（pooza の常用域）で 2 カラム・各 400', () {
      expect(
        layoutOf(800),
        const DeckLayout(visibleColumns: 2, columnWidth: 400),
      );
    });

    test('1125px で 3 カラム・各 375', () {
      expect(
        layoutOf(1125),
        const DeckLayout(visibleColumns: 3, columnWidth: 375),
      );
    });
  });

  test('カラムが本数より少なければその本数で割り、⚠ 1.5 倍で頭打ちにする', () {
    // 1200px に 2 本なら 600 ずつになるところ、375 × 1.5 = 562.5 で止める
    // （広い画面ではカラムを太くしない）。
    expect(
      layoutOf(1200, columns: 2),
      const DeckLayout(visibleColumns: 2, columnWidth: 562.5),
    );
  });

  test('⚠ ユーザー設定の下限は 375px より下げられない', () {
    expect(layoutOf(750, min: 300), layoutOf(750));
    // 広げる方向は効く。
    expect(
      layoutOf(1000, min: 500),
      const DeckLayout(visibleColumns: 2, columnWidth: 500),
    );
  });

  test('保存された設定値も 375px 未満は 375px に丸める', () async {
    SharedPreferences.setMockInitialValues({'deck_column_width': 200.0});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(deckColumnWidthProvider), minDeckColumnWidth);
  });
}
