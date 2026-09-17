import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account_key.dart';
import 'account_manager_provider.dart';
import 'preferences_provider.dart';
import 'timeline_provider.dart';

/// Provider that fetches the user's lists.
final listsProvider = FutureProvider.autoDispose<List<PostList>>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null || adapter is! ListSupport) return [];
  return (adapter as ListSupport).getLists();
});

/// リスト TL の family キー (#1088)。
///
/// ⚠ **[id] だけを持ち、リスト名は混ぜない。**サーバー側でリスト名を変えると、
/// 同じリストなのにキーだけ別物になる（`ListTab.toKey()` が表示名を含むのに
/// `==` は id しか見ていない件・設計書 決定済み事項 4）。アカウントを含める理由は
/// [HashtagTimelineKey] と同じ。
typedef ListTimelineKey = ({AccountKey? account, String id});

/// Notifier that manages paginated list timeline fetching.
class ListTimelineNotifier
    extends AutoDisposeFamilyAsyncNotifier<TimelineState, ListTimelineKey>
    with TimelineListMutations<ListTimelineKey> {
  static const _pageSize = 20;

  @override
  Future<TimelineState> build(ListTimelineKey key) async {
    final adapter = adapterForTimelineKey(
      ref.watch(currentAccountProvider),
      key.account,
    );
    final contextKey = timelineContextKey(key.account, ListTab(id: key.id));
    if (adapter == null || adapter is! ListSupport) {
      return TimelineState(hasMore: false, contextKey: contextKey);
    }

    final hideLivecure = ref.watch(hideLivecureProvider);
    final result = await fetchUntilVisible(
      pageSize: _pageSize,
      hideLivecure: hideLivecure,
      fetch: (maxId) => (adapter as ListSupport).getListTimeline(
        key.id,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
      ),
    );
    return result.copyWith(contextKey: contextKey);
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = adapterForTimelineKey(
          ref.read(currentAccountProvider),
          arg.account,
        );
        if (adapter == null || adapter is! ListSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final lastId = base.posts.last.id;
        final hideLivecure = ref.read(hideLivecureProvider);
        final raw = await (adapter as ListSupport).getListTimeline(
          arg.id,
          query: TimelineQuery(maxId: lastId, limit: _pageSize),
        );
        final older = hideLivecure
            ? raw.where((p) => !hasLivecureTag(p)).toList()
            : raw;

        // 既にリストにある投稿は落とす (#909)。各行は id をキーにしているので、
        // ページ境界の重複をそのまま足すと Duplicate keys で描画ごと落ちる。
        final knownIds = {for (final p in base.posts) p.id};
        final appended = older.where((p) => knownIds.add(p.id)).toList();
        state = AsyncData(
          base.copyWith(
            posts: [...base.posts, ...appended],
            isLoadingMore: false,
            hasMore: raw.length >= _pageSize,
            loadMoreError: null,
          ),
        );
        return;
      } catch (e) {
        if (attempt < loadMoreMaxRetries) {
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        state = AsyncData(
          (state.valueOrNull ?? current).copyWith(
            isLoadingMore: false,
            loadMoreError: e,
          ),
        );
      }
    }
  }
}

final listTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<ListTimelineNotifier, TimelineState, ListTimelineKey>(
      ListTimelineNotifier.new,
    );
