import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'timeline_provider.dart';

/// Notifier that manages paginated bookmark fetching.
class BookmarkNotifier extends AutoDisposeAsyncNotifier<TimelineState> {
  static const _pageSize = 20;

  @override
  Future<TimelineState> build() async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! BookmarkSupport) {
      return const TimelineState(hasMore: false);
    }

    final posts = await (adapter as BookmarkSupport).getBookmarks(
      query: const TimelineQuery(limit: _pageSize),
    );

    return TimelineState(posts: posts, hasMore: posts.length >= _pageSize);
  }

  /// Load next page of bookmarks (older bookmarks).
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter == null || adapter is! BookmarkSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final lastId = base.posts.last.id;
        final older = await (adapter as BookmarkSupport).getBookmarks(
          query: TimelineQuery(maxId: lastId, limit: _pageSize),
        );

        state = AsyncData(
          base.copyWith(
            posts: [...base.posts, ...older],
            isLoadingMore: false,
            hasMore: older.length >= _pageSize,
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

final bookmarkProvider =
    AsyncNotifierProvider.autoDispose<BookmarkNotifier, TimelineState>(
      BookmarkNotifier.new,
    );
