import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'timeline_provider.dart';

/// Provider that fetches the user's clips.
final clipsProvider = FutureProvider.autoDispose<List<NoteClip>>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null || adapter is! ClipSupport) return [];
  return (adapter as ClipSupport).getClips();
}, dependencies: [currentAdapterProvider]);

/// Notifier that manages paginated clip notes fetching.
class ClipNotesNotifier
    extends AutoDisposeFamilyAsyncNotifier<TimelineState, String> {
  static const _pageSize = 20;

  @override
  Future<TimelineState> build(String arg) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! ClipSupport) {
      return const TimelineState(hasMore: false);
    }

    final posts = await (adapter as ClipSupport).getClipNotes(
      arg,
      query: const TimelineQuery(limit: _pageSize),
    );

    return TimelineState(posts: posts, hasMore: posts.length >= _pageSize);
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter == null || adapter is! ClipSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final lastId = base.posts.last.id;
        final older = await (adapter as ClipSupport).getClipNotes(
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

final clipNotesProvider = AsyncNotifierProvider.autoDispose
    .family<ClipNotesNotifier, TimelineState, String>(
      ClipNotesNotifier.new,
      dependencies: [currentAdapterProvider],
    );

/// クリップ 1 つ (#1377)。お気に入りの状態と持ち主を見るのに使う。
///
/// ⚠ ほかの人のクリップを見る口が無いアダプターでは null（ボタンを出さない）。
final clipDetailProvider = FutureProvider.autoDispose.family<NoteClip?, String>(
  (ref, clipId) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter is! ClipFavoriteSupport) return null;
    return (adapter as ClipFavoriteSupport).getClip(clipId);
  },
  dependencies: [currentAdapterProvider],
);

/// お気に入りに入れたクリップ (#1377)。
final favoriteClipsProvider = FutureProvider.autoDispose<List<NoteClip>>((
  ref,
) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter is! ClipFavoriteSupport) return const [];
  return (adapter as ClipFavoriteSupport).getFavoriteClips();
}, dependencies: [currentAdapterProvider]);
