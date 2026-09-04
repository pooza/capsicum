import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'timeline_provider.dart';

/// お気に入りした投稿の一覧 (#1071)。
///
/// ⚠ **[bookmarkProvider] とほぼ同じ形だが、ページングのカーソルが違う。**
/// ブックマークは投稿 id を `max_id` に渡しているが、`GET /api/v1/favourites`
/// は**お気に入りレコードの内部 id** で切るので、`Link` ヘッダ由来のカーソルを
/// 保持して渡す必要がある。投稿 id を渡すとページが飛ぶ。
class FavoriteNotifier extends AutoDisposeAsyncNotifier<TimelineState> {
  static const _pageSize = 20;

  /// 次ページ取得用のカーソル。⚠ **投稿 id ではない**（上記の理由）。
  String? _nextCursor;

  /// [build] の世代 (#1071・リリース前レビューで追加)。
  ///
  /// ⚠⚠ **Riverpod は Notifier インスタンスを rebuild をまたいで再利用し、
  /// `build()` だけを再実行する。**そのため `_nextCursor` は build を生き延び、
  /// **飛んでいる最中の [loadMore] から後追いで上書きされる**。
  ///
  /// 実際に起きる形: 追加読み込みが返る前に引っ張って更新 → `build()` が先に
  /// 完了 → 遅れて着地した `loadMore` が**新しい 1 ページ目に古い 2 ページ目を
  /// 連結**し、カーソルも巻き戻る。アカウント切替なら**サーバー B に A の
  /// お気に入りレコード id を `max_id` として送る**ことになる。
  ///
  /// ⚠ [bookmarkProvider] はカーソルを state（`posts.last.id`）から導くので
  /// この問題を構造的に持たない。こちらは「レコードの内部 id が要る」という
  /// 理由でフィールドに持つので、代わりに世代で守る。
  int _generation = 0;

  @override
  Future<TimelineState> build() async {
    final generation = ++_generation;
    _nextCursor = null;

    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! FavoriteSupport) {
      return const TimelineState(hasMore: false);
    }

    final result = await (adapter as FavoriteSupport).getFavorites(
      query: const TimelineQuery(limit: _pageSize),
    );
    // await をまたいだので、より新しい build に追い越されていないか確かめる。
    if (generation != _generation) return const TimelineState(hasMore: false);
    _nextCursor = result.nextCursor;

    return TimelineState(
      posts: result.posts,
      hasMore: result.nextCursor != null,
    );
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    // 開始時点の世代を控える。着地時に build が走り直していたら、この結果は
    // 古いページなので **state にもカーソルにも書かずに捨てる**。
    final generation = _generation;

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter == null || adapter is! FavoriteSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final result = await (adapter as FavoriteSupport).getFavorites(
          query: TimelineQuery(maxId: _nextCursor, limit: _pageSize),
        );
        if (generation != _generation) return;
        _nextCursor = result.nextCursor;

        state = AsyncData(
          base.copyWith(
            posts: [...base.posts, ...result.posts],
            isLoadingMore: false,
            hasMore: result.nextCursor != null,
          ),
        );
        return;
      } catch (_) {
        if (generation != _generation) return;
        if (attempt < loadMoreMaxRetries) {
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        state = AsyncData(
          (state.valueOrNull ?? current).copyWith(isLoadingMore: false),
        );
      }
    }
  }
}

final favoriteProvider =
    AsyncNotifierProvider.autoDispose<FavoriteNotifier, TimelineState>(
      FavoriteNotifier.new,
    );
