import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account_key.dart';
import '../service/sentry_op_failure.dart';
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

/// チャンネル 1 件 (#1296)。フォロー中の一覧に無いチャンネルの名前を引くため。
///
/// ⚠ 失敗はエラーのまま持つ（読む側は `valueOrNull` で ID に戻す）。消えた
/// チャンネルも ID の表示になる。
final channelProvider = FutureProvider.autoDispose.family<Channel?, String>((
  ref,
  id,
) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter is! ChannelSupport) return null;
  return (adapter as ChannelSupport).getChannel(id);
}, dependencies: [currentAdapterProvider]);

/// チャンネルの管理画面の分類 (#1051)。
enum ChannelListKind {
  featured('人気', '人気のチャンネルはありません'),
  followed('フォロー中', 'フォロー中のチャンネルはありません'),
  favorite('お気に入り', 'お気に入りのチャンネルはありません'),
  owned('自分の', '自分のチャンネルはありません');

  const ChannelListKind(this.label, this.emptyMessage);

  final String label;
  final String emptyMessage;
}

/// 一覧の取得。失敗は観測へ流してから、そのまま画面へ返す (#1353)。
Future<List<Channel>> _fetchChannelList(
  Ref ref,
  String operation,
  Future<List<Channel>> Function() fetch,
) async {
  // ⚠ 通信の前に取る。通信の間に provider が破棄されると `ref` を読めない。
  final account = ref.read(currentAccountProvider);
  try {
    return await fetch();
  } catch (e, st) {
    reportOpFailure(
      tagKey: 'channel.list',
      operation: operation,
      error: e,
      stackTrace: st,
      account: account,
    );
    rethrow;
  }
}

final channelListProvider = FutureProvider.autoDispose
    .family<List<Channel>, ChannelListKind>((ref, kind) async {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! ChannelManagementSupport) return const [];
      final support = adapter as ChannelManagementSupport;
      return _fetchChannelList(
        ref,
        kind.name,
        () => switch (kind) {
          ChannelListKind.featured => support.getFeaturedChannels(),
          ChannelListKind.followed =>
            (adapter as ChannelSupport).getFollowedChannels(),
          ChannelListKind.favorite => support.getFavoriteChannels(),
          ChannelListKind.owned => support.getOwnedChannels(),
        },
      );
    }, dependencies: [currentAdapterProvider, currentAccountProvider]);

final channelSearchProvider = FutureProvider.autoDispose
    .family<List<Channel>, String>((ref, query) async {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! ChannelManagementSupport) return const [];
      return _fetchChannelList(
        ref,
        'search',
        () => (adapter as ChannelManagementSupport).searchChannels(query),
      );
    }, dependencies: [currentAdapterProvider, currentAccountProvider]);

/// チャンネルを操作したあとに、持っている一覧を取り直す (#1051)。
///
/// ⚠ [followedChannelsProvider] も忘れない（タブとチューザが読んでいる）。
void invalidateChannels(WidgetRef ref) {
  ref.invalidate(channelListProvider);
  ref.invalidate(channelSearchProvider);
  ref.invalidate(channelProvider);
  ref.invalidate(followedChannelsProvider);
}

/// [invalidateChannels] のコンテナ版。通信の間に呼び出し元の行が破棄されても
/// 取り直せるよう、通信の前に取ったコンテナへ当てる。
void invalidateChannelsIn(ProviderContainer container) {
  container.invalidate(channelListProvider);
  container.invalidate(channelSearchProvider);
  container.invalidate(channelProvider);
  container.invalidate(followedChannelsProvider);
}

/// チャンネルのタブ / カラムに出す名前 (#1296)。
///
/// `name` → フォロー中の一覧 → 1 件取得 → ID の順で引く。
///
/// ⚠⚠ **`ChannelTab.name` は null のことが多い。**デッキのカラムは
/// `toIdentityKey`（`channel:<id>`）で保存するので、読み戻すと必ず null になる。
/// タブ UI も、名前なしで一度保存されると `==` が ID だけで比べるので、名前つきに
/// 置き換わらない。以前は `name ?? id` で、どちらも ID が出ていた。
///
/// ⚠ 1 件取得は、フォロー中の一覧が**引けたうえで見当たらない**ときだけ行う
/// （一覧の取得中に全カラムぶん取りに行かない）。一覧が失敗しているときも行う。
String channelTabLabel(WidgetRef ref, String id, String? name) {
  if (name != null) return name;
  final followed = ref.watch(followedChannelsProvider);
  if (followed.isLoading && !followed.hasValue) return id;
  final hit = channelNameFromFollowed(id, null, followed.valueOrNull);
  if (hit != null) return hit;
  return ref.watch(channelProvider(id)).valueOrNull?.name ?? id;
}

/// 保存されたチャンネルの名前。無ければ [followed]（フォロー中の一覧）から引く。
/// どちらにも無ければ null。
///
/// ⚠⚠ **引き直しはこれ 1 本** (#1304)。以前はタブの見出し（[channelTabLabel]）・
/// タブ管理・デッキの投稿の 3 か所に同じ処理があった。⚠ 見当たらなかったときの
/// 扱いは呼ぶ側で違う（見出しは 1 件取得まで行う・タブ管理は ID を出す・投稿は
/// 名前なしで開く）ので、そこは呼ぶ側に残す。
String? channelNameFromFollowed(
  String id,
  String? name,
  List<Channel>? followed,
) => name ?? followed?.where((c) => c.id == id).firstOrNull?.name;
