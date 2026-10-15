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
        TimelineLiveIngest<ChannelTimelineKey>,
        OlderCursorPaging<ChannelTimelineKey> {
  static const _pageSize = 20;

  /// チャンネルは Misskey だけで、ワードミュートは全画面なので何でもよい。
  /// 公開の流れとして `public` にしておく (#1289)。
  @override
  FilterContext get filterContext => FilterContext.public;

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
    final liveGeneration = resetLiveIngestState();
    // 前の一覧の続き読みの起点を捨て、古い続き読みに書かせない (#1292)。
    final onRawCursor = resetOlderCursor();
    // 🔴 `Account` 全体ではなく、解決したアダプタだけを見る（本線の
    // `TimelineNotifier.build` と同じ理由。全体を見ると、復帰のたびに読み直す）。
    final adapter = watchAdapterForTimelineKey(ref, key.account);
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
      filterContext: filterContext,
      pageSize: _pageSize,
      hideLivecure: hideLivecure,
      fetch: (maxId) => (adapter as ChannelSupport).getChannelTimeline(
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
    if (adapter == null || adapter is! ChannelSupport) return;
    await loadOlderPages(
      site: 'channel.loadMore',
      pageSize: _pageSize,
      fetch: (maxId) => (adapter as ChannelSupport).getChannelTimeline(
        arg.id,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
      ),
    );
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
