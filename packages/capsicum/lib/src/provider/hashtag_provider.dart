import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'timeline_provider.dart';

/// Notifier that manages paginated hashtag timeline fetching.
class HashtagTimelineNotifier
    extends AutoDisposeFamilyAsyncNotifier<TimelineState, String> {
  static const _pageSize = 20;

  @override
  Future<TimelineState> build(String arg) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! HashtagSupport) {
      return const TimelineState(hasMore: false);
    }

    final posts = await (adapter as HashtagSupport).getPostsByHashtag(
      arg,
      query: const TimelineQuery(limit: _pageSize),
    );

    return TimelineState(posts: posts, hasMore: posts.length >= _pageSize);
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    try {
      final adapter = ref.read(currentAdapterProvider);
      if (adapter == null || adapter is! HashtagSupport) return;

      final lastId = current.posts.last.id;
      final older = await (adapter as HashtagSupport).getPostsByHashtag(
        arg,
        query: TimelineQuery(maxId: lastId, limit: _pageSize),
      );

      state = AsyncData(
        current.copyWith(
          posts: [...current.posts, ...older],
          isLoadingMore: false,
          hasMore: older.length >= _pageSize,
        ),
      );
    } catch (_) {
      state = AsyncData(current.copyWith(isLoadingMore: false));
    }
  }
}

final hashtagTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<HashtagTimelineNotifier, TimelineState, String>(
      HashtagTimelineNotifier.new,
    );
