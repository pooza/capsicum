import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account_key.dart';
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

/// ハッシュタグ TL の family キー (#1088)。
///
/// [spec] は "tag" または "tag+and1+and2"（"+" は AND 指定・Mastodon の `all[]`）。
///
/// ⚠ **アカウントを含める。**含めないと、デッキで 2 アカウントの同じタグを並べた
/// ときに**同じインスタンスを共有して、片方のサーバーの投稿がもう片方に混ざる**
/// （設計書 B-4）。record は値で比較されるので、そのまま family キーになる。
typedef HashtagTimelineKey = ({AccountKey? account, String spec});

/// Notifier that manages paginated hashtag timeline fetching.
class HashtagTimelineNotifier
    extends AutoDisposeFamilyAsyncNotifier<TimelineState, HashtagTimelineKey>
    with
        TimelineListMutations<HashtagTimelineKey>,
        TimelineLiveIngest<HashtagTimelineKey> {
  static const _pageSize = 20;

  @override
  String get liveStreamKey =>
      timelineContextKey(arg.account, HashtagTab(arg.spec))!;

  @override
  TabType get liveStreamTab => HashtagTab(arg.spec);

  @override
  String? get liveHost => arg.account?.host;

  @override
  int get catchUpPageSize => _pageSize;

  /// ⚠ `getPostsByHashtag` は生のサーバー件数を返さない（本線 TL の
  /// `getTimeline` だけが [TimelineResponse] を返す）。フィルタ後の件数を
  /// `rawCount` に使うので、**サーバーが満ページを返したのに手元で削られた回は
  /// 1 ページで打ち切る**。ギャップの古い側を取りこぼしうるが、次の live 遷移と
  /// pull-to-refresh で埋まる。
  @override
  Future<CatchUpPage?> fetchCatchUpPage(String? maxId) async {
    final adapter = adapterForTimelineKey(
      ref.read(currentAccountProvider),
      arg.account,
    );
    if (adapter == null || adapter is! HashtagSupport) return null;
    final (primary, all) = parseHashtagSpec(arg.spec);
    final posts = await (adapter as HashtagSupport).getPostsByHashtag(
      primary,
      query: TimelineQuery(maxId: maxId, limit: _pageSize),
      all: all,
    );
    return (
      posts: posts,
      rawCount: posts.length,
      rawLastId: posts.lastOrNull?.id,
    );
  }

  /// 自分の投稿をこのハッシュタグ TL の先頭へ楽観的に挿入する (#887)。
  ///
  /// ホーム TL の [TimelineNotifier.insertOwnPost] (#717) と同じ狙い。呼び出し側
  /// （[readVisibleTimelines]）が「投稿がこの TL のタグを実際に持っているか」を
  /// 判定済みで、ここでは重複と実況フィルタだけを見る。ハッシュタグ TL は
  /// streaming を張っていないため、これが無いと再取得まで自分の投稿が出ない。
  void insertOwnPost(Post post) {
    final current = state.valueOrNull;
    if (current == null) return;
    if (post.filterAction == FilterAction.hide) return;
    if (ref.read(hideLivecureProvider) && hasLivecureTag(post)) return;
    if (current.posts.any((p) => p.id == post.id)) return;
    // ライブ購読 (#1098) が入ったので、未表示バッファに居るぶんも重複になる。
    if (hasPendingPost(post.id)) return;
    // ⚠ 自分の投稿は位置に関わらず即座に先頭へ出す（意図的に near-top を見ない）。
    seedLiveIngestAnchor([post, ...current.posts]);
    state = AsyncData(current.copyWith(posts: [post, ...current.posts]));
  }

  @override
  Future<TimelineState> build(HashtagTimelineKey key) async {
    // 前のタグ / アカウントの新着を、このカラムへ漏らさない (#1098)。
    resetLiveIngestState();
    final adapter = adapterForTimelineKey(
      ref.watch(currentAccountProvider),
      key.account,
    );
    final contextKey = timelineContextKey(key.account, HashtagTab(key.spec));
    if (adapter == null || adapter is! HashtagSupport) {
      return TimelineState(hasMore: false, contextKey: contextKey);
    }

    // ⚠ 配線は取得の前。トグルは watch しない（切替が build() 全体を誘発して
    // 可視のジャンプになる・#904）。初回接続は取得の後に張る。
    if (adapter is StreamSupport) {
      final streamAdapter = adapter as StreamSupport;
      ref.onDispose(() => disposeLiveStream(streamAdapter));
      listenLiveStreamToggle(streamAdapter);
    }

    final (primary, all) = parseHashtagSpec(key.spec);
    final hideLivecure = ref.watch(hideLivecureProvider);
    final result = await fetchUntilVisible(
      pageSize: _pageSize,
      hideLivecure: hideLivecure,
      fetch: (maxId) => (adapter as HashtagSupport).getPostsByHashtag(
        primary,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
        all: all,
      ),
    );
    seedLiveIngestAnchor(result.posts);
    if (adapter is StreamSupport) {
      startLiveStreamIfEnabled(adapter as StreamSupport);
    }
    return result.copyWith(
      contextKey: contextKey,
      streamConnectionState: streamConnectionState,
    );
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
        if (adapter == null || adapter is! HashtagSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final (primary, all) = parseHashtagSpec(arg.spec);
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
        // 最終失敗時は loadMoreError を立て、トリガー側の再試行抑止を効かせる
        // (#678、TimelineState / list_provider と同型の番兵パターン)。
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

final hashtagTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<HashtagTimelineNotifier, TimelineState, HashtagTimelineKey>(
      HashtagTimelineNotifier.new,
      dependencies: [currentAccountProvider],
    );
