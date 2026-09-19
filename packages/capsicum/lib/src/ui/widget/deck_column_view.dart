import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/deck_column.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/timeline_provider.dart';
import '../screen/achievement_screen.dart';
import '../screen/announcement_screen.dart';
import '../screen/chat_thread_screen.dart';
import '../screen/collection_detail_screen.dart';
import '../screen/collections_list_screen.dart';
import '../screen/flash_view_screen.dart';
import '../screen/gallery_detail_screen.dart';
import '../screen/notification_screen.dart';
import '../screen/post_detail_screen.dart';
import '../screen/post_list_screen.dart';
import '../screen/profile_screen.dart';
import '../screen/user_list_screen.dart';
import '../util/deck_tabs.dart';
import 'home_menu.dart' show tabLabel;
import 'post_tile.dart';
import 'retry_error_view.dart';

/// デッキのカラム 1 本 (#1092)。ヘッダーと中身。
///
/// ⚠ **接続インジケータとアカウントはカラムのヘッダーに出す**（`docs/deck-ui-plan.md`
/// 決定済み事項 7-2）。画面共通の AppBar に 1 個だけ置くと、N 本ある購読の
/// どれの状態でもないものを出すことになる（#793 の再発）。
class DeckColumnView extends ConsumerWidget {
  const DeckColumnView({super.key, required this.column});

  final DeckColumn column;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        children: [
          _DeckColumnHeader(column: column),
          const Divider(height: 1),
          Expanded(child: _body(ref)),
        ],
      ),
    );
  }

  Widget _body(WidgetRef ref) {
    // ⚠ カラムのアカウントは、デッキ画面がスコープで `currentAccountProvider` に
    // 渡している (#1096)。ここで食い違うのはその割り当てが壊れたときだけで、
    // **そのまま描くと別のアカウントとして操作が外に出る**（B-2）ので出さない。
    // TL の family も、キーのアカウントと現在のアカウントが一致しないと取らない。
    if (column.account != ref.watch(currentAccountKeyProvider)) {
      return const _DeckColumnMessage('このカラムを表示できません');
    }
    final account = column.account;
    return switch (column.tab) {
      TimelineTab(:final type) => () {
        final p = timelineProvider((account: account, type: type));
        return _DeckTimelineBody(
          timeline: p,
          loadMore: (ref) => ref.read(p.notifier).loadMore(),
          refresh: (ref) => ref.refresh(p.future),
          setNearTop: (ref, nearTop) =>
              ref.read(p.notifier).setNearTop(nearTop),
          flushPending: (ref) => ref.read(p.notifier).flushPending(),
        );
      }(),
      HashtagTab(:final tag) => () {
        final p = hashtagTimelineProvider((account: account, spec: tag));
        return _DeckTimelineBody(
          timeline: p,
          loadMore: (ref) => ref.read(p.notifier).loadMore(),
          refresh: (ref) => ref.refresh(p.future),
          // ライブ購読が載ったので、本線 TL と同じくスクロール中は未表示バッファ
          // へ退避し、「新着 N 件」で開く (#1098)。
          setNearTop: (ref, nearTop) =>
              ref.read(p.notifier).setNearTop(nearTop),
          flushPending: (ref) => ref.read(p.notifier).flushPending(),
        );
      }(),
      ListTab(:final id) => () {
        final p = listTimelineProvider((account: account, id: id));
        return _DeckTimelineBody(
          timeline: p,
          loadMore: (ref) => ref.read(p.notifier).loadMore(),
          refresh: (ref) => ref.refresh(p.future),
          // ライブ購読が載ったので、本線 TL と同じくスクロール中は未表示バッファ
          // へ退避し、「新着 N 件」で開く (#1098)。
          setNearTop: (ref, nearTop) =>
              ref.read(p.notifier).setNearTop(nearTop),
          flushPending: (ref) => ref.read(p.notifier).flushPending(),
        );
      }(),
      ChannelTab(:final id) => () {
        final p = channelTimelineProvider((account: account, id: id));
        return _DeckTimelineBody(
          timeline: p,
          loadMore: (ref) => ref.read(p.notifier).loadMore(),
          refresh: (ref) => ref.refresh(p.future),
          // ライブ購読が載ったので、本線 TL と同じくスクロール中は未表示バッファ
          // へ退避し、「新着 N 件」で開く (#1098)。
          setNearTop: (ref, nearTop) =>
              ref.read(p.notifier).setNearTop(nearTop),
          flushPending: (ref) => ref.read(p.notifier).flushPending(),
        );
      }(),
      NotificationsTab() => const NotificationView(),
      AnnouncementsTab() => const AnnouncementView(),
      // メッセージはフィードを持たない遷移トリガー (#439) なので、カラムにならない。
      MessagesTab() => const _DeckColumnMessage('このカラムは表示できません'),
      // カラムから開いた投稿・プロフィール (#1148)。⚠ id はサーバーローカルなので、
      // 取り直しはカラムのアカウント（スコープの currentAdapterProvider）で行う。
      PostThreadTab(:final postId) => _DeckSeededBody<Post>(
        seed: switch (column.seed) {
          final Post p when p.id == postId => p,
          _ => null,
        },
        fetch: (adapter) => adapter.getPostById(postId),
        builder: (post) => PostDetailScreen(post: post, embedded: true),
      ),
      ProfileTab(:final userId) => _DeckSeededBody<User>(
        seed: switch (column.seed) {
          final User u when u.id == userId => u,
          _ => null,
        },
        fetch: (adapter) => adapter.getUserById(userId),
        builder: (user) => ProfileScreen(user: user, embedded: true),
      ),
      // #1150: カラムの中から開いた一覧・画面。⚠ 取得はここでカラムのアカウントの
      // アダプタから組み立てる（全画面の push と同じ関数を使う）。
      final UserListTab t => switch (userListFetcher(
        ref.watch(currentAdapterProvider),
        t,
      )) {
        final fetcher? => UserListView(fetcher: fetcher),
        null => const _DeckColumnMessage('このアカウントでは表示できません'),
      },
      QuotesTab(:final postId) => switch (quotesFetcher(
        ref.watch(currentAdapterProvider),
        postId,
      )) {
        final fetcher? => PostListScreen(
          title: '引用',
          emptyMessage: '引用している投稿はありません',
          fetcher: fetcher,
          embedded: true,
        ),
        null => const _DeckColumnMessage('このアカウントでは表示できません'),
      },
      AchievementsTab(:final userId) => AchievementScreen(
        userId: userId,
        displayName: column.seed is String ? column.seed! as String : null,
        embedded: true,
      ),
      CollectionsTab(:final accountId, :final mode) => CollectionsListScreen(
        accountId: accountId,
        inCollections: mode == CollectionsMode.included,
        ownerView: mode == CollectionsMode.own,
        title: '',
        embedded: true,
      ),
      CollectionTab(:final collectionId) => CollectionDetailScreen(
        collectionId: collectionId,
        embedded: true,
      ),
      GalleryPostTab(:final postId) => _DeckSeededBody<GalleryPost>(
        seed: switch (column.seed) {
          final GalleryPost p when p.id == postId => p,
          _ => null,
        },
        fetch: (adapter) => adapter is GallerySupport
            ? (adapter as GallerySupport).getGalleryPostById(postId)
            : Future.error(UnsupportedError('gallery')),
        builder: (post) => GalleryDetailScreen(post: post, embedded: true),
      ),
      FlashTab(:final flashId) => FlashViewScreen(
        initialFlash: switch (column.seed) {
          final Flash f when f.id == flashId => f,
          _ => null,
        },
        flashId: flashId,
        embedded: true,
      ),
      ChatUserTab(:final userId) => _DeckSeededBody<User>(
        seed: switch (column.seed) {
          final User u when u.id == userId => u,
          _ => null,
        },
        fetch: (adapter) => adapter.getUserById(userId),
        builder: (user) => ChatThreadScreen(otherUser: user, embedded: true),
      ),
    };
  }
}

/// アカウントが接続されていないカラム (#1096)。
///
/// 設定バックアップから移行した直後や、到達不能なアカウント（#792）。⚠ **列からは
/// 消さない**（決定済み事項 5-1）。ログインし直す / 復帰すると、そのまま動き出す。
class DeckColumnUnavailable extends StatelessWidget {
  const DeckColumnUnavailable({super.key, required this.column});

  final DeckColumn column;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = column.account;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.dividerColor)),
      ),
      child: _DeckColumnMessage(
        '@${account.username}@${account.host} は接続されていません',
      ),
    );
  }
}

class _DeckColumnHeader extends ConsumerWidget {
  const _DeckColumnHeader({required this.column});

  final DeckColumn column;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final adapter = ref.watch(currentAdapterProvider);
    final isMastodon =
        adapter != null &&
        !adapter.capabilities.supportedTimelines.contains(TimelineType.social);
    // リスト名はキーに持たない（決定済み事項 4）ので、実行時に一覧から引く。
    // ⚠ リスト以外のカラムで一覧の取得を起こさない。
    final lists = column.tab is ListTab
        ? ref.watch(listsProvider).valueOrNull ?? const <PostList>[]
        : const <PostList>[];
    final label = tabLabel(ref, column.tab, isMastodon, adapter, lists);
    final account = column.account;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '@${account.username}@${account.host}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (column.tab case TimelineTab(
            :final type,
          ) when account == ref.watch(currentAccountKeyProvider))
            // カラムのスコープの中なので、別アカウントのカラムでもここは一致する。
            _DeckStreamDot(
              key: ValueKey(type),
              timelineKey: (account: account, type: type),
            ),
          // カラムから開いたカラムは使い捨てなので、ヘッダーで閉じられるようにする
          // (#1148)。⚠ 列から外すだけで購読は止めない（autoDispose に任せる・#1093）。
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'カラムを閉じる',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                ref.read(deckColumnsProvider.notifier).remove(column.id),
          ),
        ],
      ),
    );
  }
}

/// id から取り直す中身 (#1148)。開いた時点の中身（[seed]）があればそのまま描く。
///
/// 読み戻したカラム（起動し直した後）は [seed] が無いので、カラムのアカウントで
/// [fetch] する。
class _DeckSeededBody<T extends Object> extends ConsumerStatefulWidget {
  const _DeckSeededBody({
    required this.seed,
    required this.fetch,
    required this.builder,
  });

  final T? seed;
  final Future<T> Function(DecentralizedBackendAdapter adapter) fetch;
  final Widget Function(T value) builder;

  @override
  ConsumerState<_DeckSeededBody<T>> createState() => _DeckSeededBodyState<T>();
}

class _DeckSeededBodyState<T extends Object>
    extends ConsumerState<_DeckSeededBody<T>> {
  Future<T>? _future;

  @override
  void initState() {
    super.initState();
    if (widget.seed == null) _load();
  }

  void _load() {
    final adapter = ref.read(currentAdapterProvider);
    final future = adapter == null
        ? Future<T>.error(StateError('adapter is not ready'))
        : widget.fetch(adapter);
    // ⚠ 再試行では setState の中で作るので、FutureBuilder が購読するのは次の
    // フレーム。それより先に失敗すると「未処理の例外」として上がる（テストで
    // 実際に踏んだ）。エラーは FutureBuilder が拾うので、ここでは握っておくだけ。
    future.ignore();
    _future = future;
  }

  @override
  Widget build(BuildContext context) {
    final seed = widget.seed;
    if (seed != null) return widget.builder(seed);
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snapshot) {
        final value = snapshot.data;
        if (value != null) return widget.builder(value);
        if (snapshot.hasError) {
          return RetryErrorView(
            message: '読み込みに失敗しました',
            onRetry: () => setState(_load),
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}

/// カラム単位の接続状態 (#1092・決定済み事項 7-2)。
class _DeckStreamDot extends ConsumerWidget {
  const _DeckStreamDot({super.key, required this.timelineKey});

  final TimelineKey timelineKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(timelineProvider(timelineKey));
    final state = async.isLoading
        ? StreamConnectionState.connecting
        : async.valueOrNull?.streamConnectionState ??
              StreamConnectionState.connecting;
    final (Color color, String label) = switch (state) {
      StreamConnectionState.live => (Colors.green, 'ライブ更新中'),
      StreamConnectionState.connecting => (Colors.amber, '接続中…'),
      StreamConnectionState.disconnected => (Colors.orange, '切断 — 再接続中'),
      StreamConnectionState.exhausted => (Colors.red, '接続が不安定 — 再試行中'),
      StreamConnectionState.disabled => (Colors.grey, 'ライブ更新オフ'),
    };
    return Tooltip(
      message: label,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _DeckColumnMessage extends StatelessWidget {
  const _DeckColumnMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(message, textAlign: TextAlign.center),
    ),
  );
}

/// TL 系カラムの中身。4 系統（本線 / ハッシュタグ / リスト / チャンネル）で共有する。
///
/// ⚠ 操作を関数で受け取るのは、4 系統の Notifier の型がそれぞれ違うため。
class _DeckTimelineBody extends ConsumerStatefulWidget {
  const _DeckTimelineBody({
    required this.timeline,
    required this.loadMore,
    required this.refresh,
    this.setNearTop,
    this.flushPending,
  });

  final ProviderListenable<AsyncValue<TimelineState>> timeline;
  final Future<void> Function(WidgetRef ref) loadMore;
  final Future<TimelineState> Function(WidgetRef ref) refresh;

  /// 先頭から離れている間、ライブの新着を一覧へ差し込まず溜める (#296)。
  /// 本線 TL だけが持つ。
  final void Function(WidgetRef ref, bool nearTop)? setNearTop;
  final void Function(WidgetRef ref)? flushPending;

  @override
  ConsumerState<_DeckTimelineBody> createState() => _DeckTimelineBodyState();
}

class _DeckTimelineBodyState extends ConsumerState<_DeckTimelineBody> {
  final _scrollController = ScrollController();
  bool? _nearTop;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final position = _scrollController.position;
    final nearTop = position.pixels <= 200;
    if (widget.setNearTop != null && nearTop != _nearTop) {
      _nearTop = nearTop;
      widget.setNearTop!(ref, nearTop);
    }
    if (position.pixels >= position.maxScrollExtent - 600) {
      // 継続エラー時は自動再試行を止める (#678)。回復は引っ張って更新。
      final state = ref.read(widget.timeline).valueOrNull;
      if (state == null || state.loadMoreError != null) return;
      widget.loadMore(ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(widget.timeline);
    return timeline.when(
      skipLoadingOnRefresh: true,
      data: (state) {
        final list = state.posts.isEmpty
            ? ListView(
                controller: _scrollController,
                children: const [
                  SizedBox(height: 120),
                  Center(child: Text('投稿がありません')),
                ],
              )
            : ListView.separated(
                controller: _scrollController,
                itemCount: state.posts.length + (state.isLoadingMore ? 1 : 0),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index >= state.posts.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final post = state.posts[index];
                  // 投稿 id をキーにして State を投稿に固定する (#909)。
                  return PostTile(key: ValueKey(post.id), post: post);
                },
              );
        return Column(
          children: [
            if (state.pendingCount > 0 && widget.flushPending != null)
              TextButton(
                onPressed: () => widget.flushPending!(ref),
                child: Text('新着 ${state.pendingCount} 件'),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => widget.refresh(ref),
                child: list,
              ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => RetryErrorView(
        message: '読み込みに失敗しました',
        isRetrying: timeline.isLoading,
        onRetry: () => widget.refresh(ref),
      ),
    );
  }
}
