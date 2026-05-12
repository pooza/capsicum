import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TimelineState.copyWith — loadMoreError sentinel (#455 / #450)', () {
    test('引数省略時は既存の loadMoreError を保持する', () {
      final error = Exception('boom');
      final state = TimelineState(loadMoreError: error);

      final next = state.copyWith(isLoadingMore: false);

      expect(next.loadMoreError, same(error));
    });

    test('posts など他フィールドの更新時も loadMoreError は保持される', () {
      final error = Exception('boom');
      final state = TimelineState(loadMoreError: error);

      final next = state.copyWith(posts: const [], pendingCount: 3);

      expect(next.loadMoreError, same(error));
    });

    test('明示的に null を渡すとクリアできる（loadMore 成功時の挙動）', () {
      final state = TimelineState(loadMoreError: Exception('boom'));

      final next = state.copyWith(loadMoreError: null);

      expect(next.loadMoreError, isNull);
    });

    test('新しい例外を渡すと差し替わる（loadMore 失敗時の挙動）', () {
      final initial = Exception('first');
      final replacement = Exception('second');
      final state = TimelineState(loadMoreError: initial);

      final next = state.copyWith(loadMoreError: replacement);

      expect(next.loadMoreError, same(replacement));
    });

    test('元が null のときに引数省略しても null のまま', () {
      const state = TimelineState();

      final next = state.copyWith(isLoadingMore: true);

      expect(next.loadMoreError, isNull);
    });
  });
}
