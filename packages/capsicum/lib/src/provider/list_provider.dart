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
}, dependencies: [currentAdapterProvider]);

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
    with
        TimelineListMutations<ListTimelineKey>,
        TimelineLiveIngest<ListTimelineKey>,
        OlderCursorPaging<ListTimelineKey> {
  static const _pageSize = 20;

  /// リストは `home`（Mastodon Web と同じ・#1289）。
  @override
  FilterContext get filterContext => FilterContext.home;

  @override
  String get liveStreamKey =>
      timelineContextKey(arg.account, ListTab(id: arg.id))!;

  @override
  TabType get liveStreamTab => ListTab(id: arg.id);

  @override
  String? get liveHost => arg.account?.host;

  @override
  int get catchUpPageSize => _pageSize;

  /// ⚠ 生のサーバー件数が取れない件は [HashtagTimelineNotifier.fetchCatchUpPage]
  /// と同じ。
  @override
  Future<CatchUpPage?> fetchCatchUpPage(String? maxId) async {
    final adapter = adapterForTimelineKey(
      ref.read(currentAccountProvider),
      arg.account,
    );
    if (adapter == null || adapter is! ListSupport) return null;
    final posts = await (adapter as ListSupport).getListTimeline(
      arg.id,
      query: TimelineQuery(maxId: maxId, limit: _pageSize),
    );
    return (
      posts: posts,
      rawCount: posts.length,
      rawLastId: posts.lastOrNull?.id,
    );
  }

  @override
  Future<TimelineState> build(ListTimelineKey key) async {
    // 前のリスト / アカウントの新着を、このカラムへ漏らさない (#1098)。
    final liveGeneration = resetLiveIngestState();
    // 前の一覧の続き読みの起点を捨て、古い続き読みに書かせない (#1292)。
    final onRawCursor = resetOlderCursor();
    // 🔴 `Account` 全体ではなく、解決したアダプタだけを見る（本線の
    // `TimelineNotifier.build` と同じ理由。全体を見ると、復帰のたびに読み直す）。
    final adapter = watchAdapterForTimelineKey(ref, key.account);
    final contextKey = timelineContextKey(key.account, ListTab(id: key.id));
    if (adapter == null || adapter is! ListSupport) {
      return TimelineState(hasMore: false, contextKey: contextKey);
    }

    // ⚠ 配線は取得の前・初回接続は取得の後（理由は #904・ハッシュタグ側と同じ）。
    if (adapter is StreamSupport) {
      final streamAdapter = adapter as StreamSupport;
      ref.onDispose(() => disposeLiveStream(streamAdapter));
      listenLiveStreamToggle(streamAdapter);
    }

    final hideLivecure = ref.watch(hideLivecureProvider);
    final result = await fetchUntilVisible(
      filterContext: filterContext,
      pageSize: _pageSize,
      hideLivecure: hideLivecure,
      fetch: (maxId) => (adapter as ListSupport).getListTimeline(
        key.id,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
      ),
      // ⚠ 最初の読み込みで進めたぶんを、続き読みへ渡す (#1292)。
      onRawCursor: onRawCursor,
    );
    seedLiveIngestAnchor(result.posts);
    if (adapter is StreamSupport) {
      startLiveStreamIfEnabled(
        adapter as StreamSupport,
        generation: liveGeneration,
      );
    }
    return result.copyWith(
      contextKey: contextKey,
      streamConnectionState: streamConnectionState,
    );
  }

  /// 続きを読む。起点・空振りの続け方・世代のガードは [OlderCursorPaging]
  /// (#1292)。
  Future<void> loadMore() async {
    final adapter = adapterForTimelineKey(
      ref.read(currentAccountProvider),
      arg.account,
    );
    if (adapter == null || adapter is! ListSupport) return;
    await loadOlderPages(
      site: 'list.loadMore',
      pageSize: _pageSize,
      fetch: (maxId) => (adapter as ListSupport).getListTimeline(
        arg.id,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
      ),
    );
  }
}

final listTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<ListTimelineNotifier, TimelineState, ListTimelineKey>(
      ListTimelineNotifier.new,
      dependencies: [currentAccountProvider],
    );
