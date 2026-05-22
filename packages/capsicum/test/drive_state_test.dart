import 'package:capsicum/src/provider/drive_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group(
    'shouldAutoLoadMore — drive_manager_screen post-frame contract (#456)',
    () {
      test('state == null では発火しない', () {
        expect(shouldAutoLoadMore(null), isFalse);
      });

      test(
        '通常の状態 (hasMore=true, isLoadingMore=false, loadMoreError=null) で発火',
        () {
          expect(shouldAutoLoadMore(const DriveState()), isTrue);
        },
      );

      test('hasMore=false では発火しない', () {
        expect(shouldAutoLoadMore(const DriveState(hasMore: false)), isFalse);
      });

      test('isLoadingMore=true では発火しない', () {
        expect(
          shouldAutoLoadMore(const DriveState(isLoadingMore: true)),
          isFalse,
        );
      });

      test('loadMoreError != null では発火しない (sentinel 由来の前回失敗を尊重)', () {
        expect(
          shouldAutoLoadMore(DriveState(loadMoreError: Exception('boom'))),
          isFalse,
        );
      });

      test('複数条件 NG が同時に成立しても false', () {
        expect(
          shouldAutoLoadMore(
            DriveState(
              hasMore: false,
              isLoadingMore: true,
              loadMoreError: Exception('boom'),
            ),
          ),
          isFalse,
        );
      });
    },
  );

  group('DriveState.copyWith — loadMoreError sentinel (#450)', () {
    test('引数省略時は既存の loadMoreError を保持する', () {
      final error = Exception('boom');
      final state = DriveState(loadMoreError: error);

      final next = state.copyWith(isLoadingMore: false);

      expect(next.loadMoreError, same(error));
    });

    test('files など他フィールドの更新時も loadMoreError は保持される', () {
      final error = Exception('boom');
      final state = DriveState(loadMoreError: error);

      final next = state.copyWith(folders: const [], files: const []);

      expect(next.loadMoreError, same(error));
    });

    test('明示的に null を渡すとクリアできる（loadMore 成功時の挙動）', () {
      final state = DriveState(loadMoreError: Exception('boom'));

      final next = state.copyWith(loadMoreError: null);

      expect(next.loadMoreError, isNull);
    });

    test('新しい例外を渡すと差し替わる（loadMore 失敗時の挙動）', () {
      final initial = Exception('first');
      final replacement = Exception('second');
      final state = DriveState(loadMoreError: initial);

      final next = state.copyWith(loadMoreError: replacement);

      expect(next.loadMoreError, same(replacement));
    });

    test('元が null のときに引数省略しても null のまま', () {
      const state = DriveState();

      final next = state.copyWith(isLoadingMore: true);

      expect(next.loadMoreError, isNull);
    });
  });
}
