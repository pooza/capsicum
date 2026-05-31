import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #583 / #230: list/hashtag/channel の build() が共有する fetchUntilVisible が、
/// 実況フィルタで1ページ目が全滅しても空タイムラインを返さず、表示可能な投稿が
/// 見つかるか枯渇するまでページを辿ることを検証する。

User _user() => const User(id: 'u1', username: 'alice');

Post _post(String id, {required bool livecure}) => Post(
  id: id,
  postedAt: DateTime(2026, 5, 18),
  author: _user(),
  // _livecurePattern は "#実況" の末尾一致でも判定される。
  content: livecure ? 'みてる #実況' : 'ただの投稿',
);

void main() {
  group('fetchUntilVisible (#583 / #230)', () {
    test('1ページ目が全て #実況 なら次ページを自動取得して可視投稿を返す', () async {
      final pages = <List<Post>>[
        [_post('a', livecure: true), _post('b', livecure: true)],
        [_post('c', livecure: false), _post('d', livecure: true)],
      ];
      var calls = 0;

      final state = await fetchUntilVisible(
        pageSize: 2,
        hideLivecure: true,
        fetch: (maxId) async => pages[calls++],
      );

      expect(calls, 2, reason: '2ページ目まで取得すること');
      expect(state.posts.map((p) => p.id), ['c']);
      expect(state.hasMore, isTrue);
    });

    test('可視投稿が見つかった時点で過剰なページ取得をしない', () async {
      var calls = 0;
      final state = await fetchUntilVisible(
        pageSize: 2,
        hideLivecure: true,
        fetch: (maxId) async {
          calls++;
          if (calls == 1) {
            return [_post('a', livecure: true), _post('b', livecure: true)];
          }
          return [_post('c', livecure: false), _post('d', livecure: false)];
        },
      );

      expect(calls, 2);
      expect(state.posts.map((p) => p.id), ['c', 'd']);
    });

    test('全件 #実況 で枯渇しても無限ループせず空+hasMore=false で終わる', () async {
      var calls = 0;
      final state = await fetchUntilVisible(
        pageSize: 2,
        hideLivecure: true,
        fetch: (maxId) async {
          calls++;
          if (calls == 1) {
            return [_post('a', livecure: true), _post('b', livecure: true)];
          }
          return [_post('c', livecure: true)]; // 端数ページ → hasMore false
        },
      );

      expect(calls, 2);
      expect(state.posts, isEmpty);
      expect(state.hasMore, isFalse);
    });

    test('hideLivecure=false なら1ページ目をそのまま返す', () async {
      var calls = 0;
      final state = await fetchUntilVisible(
        pageSize: 2,
        hideLivecure: false,
        fetch: (maxId) async {
          calls++;
          return [_post('a', livecure: true), _post('b', livecure: true)];
        },
      );

      expect(calls, 1, reason: 'フィルタしないので追加取得は不要');
      expect(state.posts.map((p) => p.id), ['a', 'b']);
      expect(state.hasMore, isTrue);
    });

    test('ページネーションカーソルに直前ページ末尾の id を渡す', () async {
      final seenCursors = <String?>[];
      var calls = 0;

      await fetchUntilVisible(
        pageSize: 2,
        hideLivecure: true,
        fetch: (maxId) async {
          seenCursors.add(maxId);
          calls++;
          if (calls == 1) {
            return [_post('a', livecure: true), _post('b', livecure: true)];
          }
          return [_post('c', livecure: false)];
        },
      );

      expect(seenCursors, [null, 'b']);
    });

    /// #601: API が満杯ページを返し続けても kMaxVisibilityPageFetches で打ち切る。
    test('満杯ページが続いても上限ページ数で打ち切る', () async {
      var calls = 0;
      final state = await fetchUntilVisible(
        pageSize: 2,
        hideLivecure: true,
        fetch: (maxId) async {
          calls++;
          return [
            _post('a$calls', livecure: true),
            _post('b$calls', livecure: true),
          ];
        },
      );

      expect(calls, kMaxVisibilityPageFetches, reason: '上限ページ数で打ち切る');
      expect(state.posts, isEmpty);
      expect(
        state.hasMore,
        isTrue,
        reason: 'API はまだデータを持っているので hasMore は true',
      );
      expect(
        state.pageCapHit,
        isTrue,
        reason: '上限到達 + 全件フィルタ除外なので #624 のフラグが立つ',
      );
    });
  });
}
