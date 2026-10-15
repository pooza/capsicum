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
        TimelineLiveIngest<ListTimelineKey> {
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
    _olderCursor = null;
    final result = await fetchUntilVisible(
      filterContext: filterContext,
      pageSize: _pageSize,
      hideLivecure: hideLivecure,
      fetch: (maxId) => (adapter as ListSupport).getListTimeline(
        key.id,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
      ),
      // ⚠ 最初の読み込みで進めたぶんを、続き読みへ渡す (#1292)。
      onRawCursor: (rawLastId) => _olderCursor = rawLastId,
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

  /// 続き読みの、**消す前の**末尾の id（次に引く起点・#1292）。
  ///
  /// ⚠⚠ **表示中の最後の投稿を起点にしない。**実況フィルタやフィルターの
  /// 「完全に隠す」で 1 ページぶんが丸ごと落ちると、表示中の最後は動かないので、
  /// 同じページを引き直し続けて先へ進めなくなる。ハッシュタグ TL と同じ形。
  String? _olderCursor;

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

        final hideLivecure = ref.read(hideLivecureProvider);
        var cursor =
            _olderCursor ?? (state.valueOrNull ?? current).posts.lastOrNull?.id;
        final older = <Post>[];
        var hasMore = true;
        // ⚠ 絞った結果が空のページは、上限まで続けて先を引く (#1292)。
        for (var page = 0; page < kMaxEmptyOlderPages; page++) {
          final raw = await (adapter as ListSupport).getListTimeline(
            arg.id,
            query: TimelineQuery(maxId: cursor, limit: _pageSize),
          );
          if (raw.isNotEmpty) cursor = raw.last.id;
          older.addAll(
            raw
                .where((p) => !p.isHiddenIn(filterContext))
                .where((p) => !hideLivecure || !hasLivecureTag(p)),
          );
          hasMore = raw.length >= _pageSize;
          if (older.isNotEmpty || !hasMore) break;
        }
        _olderCursor = cursor;

        // 既にリストにある投稿は落とす (#909)。各行は id をキーにしているので、
        // ページ境界の重複をそのまま足すと Duplicate keys で描画ごと落ちる。
        final base = state.valueOrNull ?? current;
        final knownIds = {for (final p in base.posts) p.id};
        final appended = older.where((p) => knownIds.add(p.id)).toList();
        state = AsyncData(
          base.copyWith(
            posts: [...base.posts, ...appended],
            isLoadingMore: false,
            hasMore: hasMore,
            loadMoreError: null,
            // 上限まで引いても見える投稿が出なかった。末尾に「さらに古い投稿を
            // 探す」を出して、手で先へ進めるようにする (#1292)。
            pageCapHit: older.isEmpty && hasMore,
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
      dependencies: [currentAccountProvider],
    );
