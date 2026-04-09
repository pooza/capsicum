import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'preferences_provider.dart';
import 'timeline_provider.dart';

/// Parse a pinned hashtag spec ("tag" or "tag+and1+and2") into parts.
(String, List<String>?) parseHashtagSpec(String spec) {
  final parts = spec.split('+');
  final primary = parts.first;
  final all = parts.length > 1 ? parts.sublist(1) : null;
  return (primary, all);
}

/// Format a display label for a hashtag spec.
String hashtagSpecLabel(String spec) => '#${spec.replaceAll('+', ' + #')}';

/// Notifier that manages paginated hashtag timeline fetching.
///
/// The family key is a hashtag spec: "tag" or "tag+and1+and2" where "+"
/// separates AND-matched tags (Mastodon `all[]` parameter).
class HashtagTimelineNotifier
    extends AutoDisposeFamilyAsyncNotifier<TimelineState, String> {
  static const _pageSize = 20;

  @override
  Future<TimelineState> build(String arg) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! HashtagSupport) {
      return const TimelineState(hasMore: false);
    }

    final (primary, all) = parseHashtagSpec(arg);
    final hideLivecure = ref.watch(hideLivecureProvider);
    final posts = await (adapter as HashtagSupport).getPostsByHashtag(
      primary,
      query: const TimelineQuery(limit: _pageSize),
      all: all,
    );
    final visible = hideLivecure
        ? posts.where((p) => !hasLivecureTag(p)).toList()
        : posts;

    return TimelineState(posts: visible, hasMore: posts.length >= _pageSize);
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter == null || adapter is! HashtagSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final (primary, all) = parseHashtagSpec(arg);
        final base = state.valueOrNull ?? current;
        final lastId = base.posts.last.id;
        final hideLivecure = ref.read(hideLivecureProvider);
        final raw = await (adapter as HashtagSupport).getPostsByHashtag(
          primary,
          query: TimelineQuery(maxId: lastId, limit: _pageSize),
          all: all,
        );
        final older = hideLivecure
            ? raw.where((p) => !hasLivecureTag(p)).toList()
            : raw;

        state = AsyncData(
          base.copyWith(
            posts: [...base.posts, ...older],
            isLoadingMore: false,
            hasMore: raw.length >= _pageSize,
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

final hashtagTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<HashtagTimelineNotifier, TimelineState, String>(
      HashtagTimelineNotifier.new,
    );
