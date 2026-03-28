import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'timeline_provider.dart' show loadMoreMaxRetries, loadMoreRetryDelay;

class GalleryState {
  final List<GalleryPost> posts;
  final bool isLoadingMore;
  final bool hasMore;

  const GalleryState({
    this.posts = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
  });

  GalleryState copyWith({
    List<GalleryPost>? posts,
    bool? isLoadingMore,
    bool? hasMore,
  }) {
    return GalleryState(
      posts: posts ?? this.posts,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

/// Featured gallery posts (for drawer menu).
class GalleryPostsNotifier extends AutoDisposeAsyncNotifier<GalleryState> {
  static const _pageSize = 20;

  @override
  Future<GalleryState> build() async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! GallerySupport) {
      return const GalleryState(hasMore: false);
    }

    final posts = await (adapter as GallerySupport).getGalleryPosts(
      query: const TimelineQuery(limit: _pageSize),
    );
    return GalleryState(posts: posts, hasMore: posts.length >= _pageSize);
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter == null || adapter is! GallerySupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final lastId = base.posts.last.id;
        final older = await (adapter as GallerySupport).getGalleryPosts(
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

final galleryPostsProvider =
    AsyncNotifierProvider.autoDispose<GalleryPostsNotifier, GalleryState>(
      GalleryPostsNotifier.new,
    );

/// Gallery posts for a specific user (for profile screen).
class UserGalleryPostsNotifier
    extends AutoDisposeFamilyAsyncNotifier<GalleryState, String> {
  static const _pageSize = 20;

  @override
  Future<GalleryState> build(String arg) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! GallerySupport) {
      return const GalleryState(hasMore: false);
    }

    final posts = await (adapter as GallerySupport).getUserGalleryPosts(
      arg,
      query: const TimelineQuery(limit: _pageSize),
    );
    return GalleryState(posts: posts, hasMore: posts.length >= _pageSize);
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter == null || adapter is! GallerySupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final lastId = base.posts.last.id;
        final older = await (adapter as GallerySupport).getUserGalleryPosts(
          arg,
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

final userGalleryPostsProvider = AsyncNotifierProvider.autoDispose
    .family<UserGalleryPostsNotifier, GalleryState, String>(
      UserGalleryPostsNotifier.new,
    );
