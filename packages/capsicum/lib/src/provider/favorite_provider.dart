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

  @override
  Future<TimelineState> build() async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! FavoriteSupport) {
      return const TimelineState(hasMore: false);
    }

    final result = await (adapter as FavoriteSupport).getFavorites(
      query: const TimelineQuery(limit: _pageSize),
    );
    _nextCursor = result.nextCursor;

    return TimelineState(
      posts: result.posts,
      hasMore: result.nextCursor != null && result.posts.length >= _pageSize,
    );
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

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
        _nextCursor = result.nextCursor;

        state = AsyncData(
          base.copyWith(
            posts: [...base.posts, ...result.posts],
            isLoadingMore: false,
            hasMore:
                result.nextCursor != null && result.posts.length >= _pageSize,
          ),
        );
        return;
      } catch (_) {
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
