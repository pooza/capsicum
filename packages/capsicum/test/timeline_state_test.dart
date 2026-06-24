import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
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

  group('TimelineState.contextKey 伝播 (#758)', () {
    test('copyWith は引数省略時に既存の contextKey を保持する', () {
      const state = TimelineState(contextKey: 'mastodon://u@h|tl:home');

      // loadMore / streaming は copyWith で posts などだけ差し替えるため、
      // contextKey が落ちると切替直後でないのにローディングへ落ちてしまう。
      final next = state.copyWith(isLoadingMore: true);

      expect(next.contextKey, 'mastodon://u@h|tl:home');
    });

    test('copyWith に contextKey を渡すと差し替わる（build() の付与）', () {
      const state = TimelineState(contextKey: 'mastodon://u@h|tag:foo');

      final next = state.copyWith(contextKey: 'mastodon://u@h|tag:bar');

      expect(next.contextKey, 'mastodon://u@h|tag:bar');
    });
  });

  group('timelineContextKey (#758)', () {
    const key = AccountKey(
      type: BackendType.mastodon,
      host: 'mstdn.example',
      username: 'alice',
    );

    test('アカウントキー + 種別から安定したキーを組み立てる', () {
      expect(
        timelineContextKey(key, 'tl:home'),
        'mastodon://alice@mstdn.example|tl:home',
      );
    });

    test('種別が違えばキーも変わる（同一アカウント内のタブ切替を区別）', () {
      expect(
        timelineContextKey(key, 'tl:home'),
        isNot(timelineContextKey(key, 'tl:local')),
      );
    });

    test('アカウントキーが null のときは null', () {
      expect(timelineContextKey(null, 'tl:home'), isNull);
    });
  });
}
