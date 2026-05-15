import 'package:capsicum/src/provider/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatThreadState.copyWith — loadMoreError sentinel (#442)', () {
    test('引数省略時は既存の loadMoreError を保持する', () {
      final error = Exception('boom');
      final state = ChatThreadState(loadMoreError: error);

      final next = state.copyWith(isLoadingMore: false);

      expect(next.loadMoreError, same(error));
    });

    test('messages 等他フィールドの更新時も loadMoreError は保持される', () {
      final error = Exception('boom');
      final state = ChatThreadState(loadMoreError: error);

      final next = state.copyWith(messages: const [], hasMore: false);

      expect(next.loadMoreError, same(error));
    });

    test('明示的に null を渡すとクリアできる', () {
      final state = ChatThreadState(loadMoreError: Exception('boom'));

      final next = state.copyWith(loadMoreError: null);

      expect(next.loadMoreError, isNull);
    });

    test('新しい例外を渡すと差し替わる', () {
      final initial = Exception('first');
      final replacement = Exception('second');
      final state = ChatThreadState(loadMoreError: initial);

      final next = state.copyWith(loadMoreError: replacement);

      expect(next.loadMoreError, same(replacement));
    });

    test('元が null のときに引数省略しても null のまま', () {
      const state = ChatThreadState();

      final next = state.copyWith(isLoadingMore: true);

      expect(next.loadMoreError, isNull);
    });
  });
}
