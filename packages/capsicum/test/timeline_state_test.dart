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

  group('TimelineState — reconnectCount / lastDisconnectedAt (#782)', () {
    test('デフォルトは 0 / null', () {
      const state = TimelineState();
      expect(state.reconnectCount, 0);
      expect(state.lastDisconnectedAt, isNull);
    });

    test('copyWith で再接続カウントと直近切断時刻を更新できる', () {
      final at = DateTime(2026, 6, 29, 10, 15, 30);
      final next = const TimelineState().copyWith(
        reconnectCount: 3,
        lastDisconnectedAt: at,
      );
      expect(next.reconnectCount, 3);
      expect(next.lastDisconnectedAt, at);
    });

    test('copyWith 省略時は既存値を保持する', () {
      final at = DateTime(2026, 6, 29, 10, 15, 30);
      final base = TimelineState(reconnectCount: 5, lastDisconnectedAt: at);
      final next = base.copyWith(pendingCount: 1);
      expect(next.reconnectCount, 5);
      expect(next.lastDisconnectedAt, at);
    });
  });

  group('comparePostIdDesc — ギャップ補完の id 整列 (#781)', () {
    test('Mastodon 数値 id を新しい順（降順）で比較する', () {
      expect(comparePostIdDesc('100', '99'), lessThan(0));
      expect(comparePostIdDesc('99', '100'), greaterThan(0));
      expect(comparePostIdDesc('100', '100'), 0);
    });

    test('数値 id は桁数が違っても数として比較する（文字列比較の罠を回避）', () {
      // 文字列比較だと "9" > "100" になってしまうケース。
      expect(
        comparePostIdDesc('1000000000000000000', '999999999999999999'),
        lessThan(0),
      );
      expect(comparePostIdDesc('9', '100'), greaterThan(0));
    });

    test('Misskey の aid は辞書順（時系列）で比較する', () {
      // aid は新しいほど辞書順で後ろ。降順なら後ろの方が先に来る。
      expect(comparePostIdDesc('9abd', '9abc'), lessThan(0));
      expect(comparePostIdDesc('9abc', '9abd'), greaterThan(0));
    });

    test('リストを sort すると新しい順に並ぶ（数値）', () {
      final ids = ['97', '100', '99', '101', '98']..sort(comparePostIdDesc);
      expect(ids, ['101', '100', '99', '98', '97']);
    });

    test('リストを sort すると新しい順に並ぶ（aid）', () {
      final ids = ['9aa3', '9aa1', '9aa5', '9aa2']..sort(comparePostIdDesc);
      expect(ids, ['9aa5', '9aa3', '9aa2', '9aa1']);
    });
  });
}
