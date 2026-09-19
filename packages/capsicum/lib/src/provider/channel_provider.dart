import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account_key.dart';
import 'account_manager_provider.dart';
import 'preferences_provider.dart';
import 'timeline_provider.dart';

/// チャンネル TL の family キー (#1088)。持ち方の理由は [ListTimelineKey] と同じ
/// （id だけ・チャンネル名は混ぜない・アカウントを含める）。
typedef ChannelTimelineKey = ({AccountKey? account, String id});

/// Notifier that manages paginated channel timeline fetching.
class ChannelTimelineNotifier
    extends AutoDisposeFamilyAsyncNotifier<TimelineState, ChannelTimelineKey>
    with
        TimelineListMutations<ChannelTimelineKey>,
        TimelineLiveIngest<ChannelTimelineKey> {
  static const _pageSize = 20;

  @override
  String get liveStreamKey =>
      timelineContextKey(arg.account, ChannelTab(id: arg.id))!;

  @override
  TabType get liveStreamTab => ChannelTab(id: arg.id);

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
    if (adapter == null || adapter is! ChannelSupport) return null;
    final posts = await (adapter as ChannelSupport).getChannelTimeline(
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
  Future<TimelineState> build(ChannelTimelineKey key) async {
    // 前のチャンネル / アカウントの新着を、このカラムへ漏らさない (#1098)。
    resetLiveIngestState();
    final adapter = adapterForTimelineKey(
      ref.watch(currentAccountProvider),
      key.account,
    );
    // ⚠ contextKey はギャップ補完 (#781) の stale 判定が読む。ここだけ空のまま
    // だったので、他の TL と同じく入れる。
    final contextKey = timelineContextKey(key.account, ChannelTab(id: key.id));
    if (adapter == null || adapter is! ChannelSupport) {
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
      pageSize: _pageSize,
      hideLivecure: hideLivecure,
      fetch: (maxId) => (adapter as ChannelSupport).getChannelTimeline(
        key.id,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
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
        if (adapter == null || adapter is! ChannelSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final lastId = base.posts.last.id;
        final hideLivecure = ref.read(hideLivecureProvider);
        final raw = await (adapter as ChannelSupport).getChannelTimeline(
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

final channelTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<ChannelTimelineNotifier, TimelineState, ChannelTimelineKey>(
      ChannelTimelineNotifier.new,
      dependencies: [currentAccountProvider],
    );

/// 現在アカウントがフォロー中のチャンネル一覧 (#334 タブ管理から参照)。
/// ChannelSupport を持たない adapter では空配列を返す。
/// フォロー中のチャンネル。
///
/// ⚠ **失敗を握り潰さない** (#1156)。以前は `catch` で空を返しており、**取得に
/// 失敗しても「フォローしているチャンネルが 0 件」と同じ**になっていた。候補や
/// タブに何も出ないのに理由が分からず、再試行の機会も無かった。読む側は
/// `valueOrNull` で受けているので、エラーは「未確定」として扱われる
/// （[visibleTabsProvider] は capability 判定だけにフォールバックする）。
///
/// ⚠ `autoDispose` を付けていないのは [visibleTabsProvider] が常時 watch して
/// いるため。**取り直しは明示的に `ref.invalidate` で行う**（シートを開いたとき）。
final followedChannelsProvider = FutureProvider<List<Channel>>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter is! ChannelSupport) return const [];
  return (adapter as ChannelSupport).getFollowedChannels();
}, dependencies: [currentAdapterProvider]);
