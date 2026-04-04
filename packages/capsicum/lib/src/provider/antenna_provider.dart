import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'timeline_provider.dart';

/// Provider that fetches the user's antennas.
final antennasProvider = FutureProvider.autoDispose<List<Antenna>>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null || adapter is! AntennaSupport) return [];
  return (adapter as AntennaSupport).getAntennas();
});

/// Notifier that manages paginated antenna notes fetching.
class AntennaNotesNotifier
    extends AutoDisposeFamilyAsyncNotifier<TimelineState, String> {
  static const _pageSize = 20;

  @override
  Future<TimelineState> build(String arg) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! AntennaSupport) {
      return const TimelineState(hasMore: false);
    }

    final posts = await (adapter as AntennaSupport).getAntennaNotes(
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
        if (adapter == null || adapter is! AntennaSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final lastId = base.posts.last.id;
        final older = await (adapter as AntennaSupport).getAntennaNotes(
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

final antennaNotesProvider = AsyncNotifierProvider.autoDispose
    .family<AntennaNotesNotifier, TimelineState, String>(
      AntennaNotesNotifier.new,
    );
