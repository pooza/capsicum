import 'package:capsicum/src/ui/util/deck_close_unlocked.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1307: ロックしていないカラムをまとめて閉じる（2026-10-27 pooza 判断）。
void main() {
  const columns = ['a', 'b', 'c', 'd', 'e'];

  group('閉じる対象', () {
    test('ロックしていないカラムを、列の順で返す', () {
      expect(unlockedDeckColumnIdsToClose(columns, {'b', 'd'}), [
        'a',
        'c',
        'e',
      ]);
    });

    test('⚠ ロック中が無ければ空（押せない）', () {
      expect(unlockedDeckColumnIdsToClose(columns, {}), isEmpty);
    });

    test('⚠ 列に居ない id のロックは数えない', () {
      expect(unlockedDeckColumnIdsToClose(columns, {'z'}), isEmpty);
    });

    test('⚠ 全部ロック中なら空（閉じるものが無い）', () {
      expect(unlockedDeckColumnIdsToClose(columns, columns.toSet()), isEmpty);
    });
  });

  group('閉じたあとのフォーカス', () {
    test('フォーカス中がロック中ならそのまま', () {
      expect(deckFocusAfterClosingUnlocked(columns, {'b', 'd'}, 'd'), 'd');
    });

    test('そうでなければ、左にあるいちばん近いロック中', () {
      expect(deckFocusAfterClosingUnlocked(columns, {'a', 'b', 'e'}, 'd'), 'b');
    });

    test('左に無ければ、右にあるいちばん近いロック中', () {
      expect(deckFocusAfterClosingUnlocked(columns, {'d', 'e'}, 'b'), 'd');
    });

    test('フォーカスが無い・列に居なければ、先頭のロック中', () {
      expect(deckFocusAfterClosingUnlocked(columns, {'c', 'e'}, null), 'c');
      expect(deckFocusAfterClosingUnlocked(columns, {'c', 'e'}, 'z'), 'c');
    });

    test('⚠ 押せないときは null', () {
      expect(deckFocusAfterClosingUnlocked(columns, {}, 'a'), isNull);
      expect(
        deckFocusAfterClosingUnlocked(columns, columns.toSet(), 'a'),
        isNull,
      );
    });
  });
}
