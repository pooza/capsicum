import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../util/scroll_thresholds.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/channel_actions_sheet.dart';
import '../widget/post_tile.dart';
import '../widget/retry_error_view.dart';
import '../widget/simple_post_bar.dart';
import '../widget/timeline_older_prompt.dart';

/// チャンネルタイムラインの本体（Scaffold/AppBar を持たない）。
///
/// HomeScreen にタブとして埋め込む経路 (#334) と、ドロワー由来の
/// [ChannelTimelineScreen] から push する経路の両方で使う。
class ChannelTimelineView extends ConsumerStatefulWidget {
  final String channelId;
  final String? channelName;

  const ChannelTimelineView({
    super.key,
    required this.channelId,
    this.channelName,
  });

  @override
  ConsumerState<ChannelTimelineView> createState() =>
      _ChannelTimelineViewState();
}

class _ChannelTimelineViewState extends ConsumerState<ChannelTimelineView> {
  final _scrollController = ScrollController();
  final _nearTopTracker = NearTopTracker();

  ChannelTimelineKey get _key =>
      (account: ref.read(currentAccountKeyProvider), id: widget.channelId);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // ⚠ 開いた時点で「先頭に居る」と名乗る (#1235)。理由は
    // `list_timeline_screen.dart` の同じ箇所。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(channelTimelineProvider(_key).notifier).setNearTop(true);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 読み進めている間は、ライブの新着を未表示バッファへ退避させる (#1235)。
    _nearTopTracker.update(
      _scrollController.position,
      (nearTop) =>
          ref.read(channelTimelineProvider(_key).notifier).setNearTop(nearTop),
    );
    if (shouldLoadMore(_scrollController.position)) {
      // 継続エラー時 (loadMoreError) は自動再試行を止める (#678)。isLoadingMore /
      // hasMore は loadMore 側でも弾くが、リトライストーム抑止のため loadMoreError
      // はトリガー段で見る。回復は pull-to-refresh で build() 再実行時。
      final key = _key;
      final state = ref.read(channelTimelineProvider(key)).valueOrNull;
      if (state != null && state.loadMoreError != null) return;
      ref.read(channelTimelineProvider(key).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ChannelTimelineKey key = (
      account: ref.watch(currentAccountKeyProvider),
      id: widget.channelId,
    );
    final timeline = ref.watch(channelTimelineProvider(key));
    final adapter = ref.watch(currentAdapterProvider);
    final canPost = adapter is ChannelSupport;

    return Column(
      children: [
        Expanded(
          child: timeline.when(
            data: (state) => state.posts.isEmpty
                ? TimelineEmptyOrOlder(
                    hasMore: state.hasMore,
                    isLoadingMore: state.isLoadingMore,
                    onLoadOlder: () => ref
                        .read(channelTimelineProvider(key).notifier)
                        .loadMore(),
                  )
                : RefreshIndicator(
                    onRefresh: () =>
                        ref.refresh(channelTimelineProvider(key).future),
                    child: ListView.separated(
                      controller: _scrollController,
                      itemCount:
                          state.posts.length +
                          olderTailCount(
                            isLoadingMore: state.isLoadingMore,
                            stalled: olderStalled(state),
                          ),
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index >= state.posts.length) {
                          return TimelineOlderTail(
                            isLoadingMore: state.isLoadingMore,
                            onLoadOlder: () => ref
                                .read(channelTimelineProvider(key).notifier)
                                .loadMore(),
                          );
                        }
                        return PostTile(
                          key: ValueKey(state.posts[index].id),
                          post: state.posts[index],
                        );
                      },
                    ),
                  ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) => RetryErrorView(
              message: '読み込みに失敗しました',
              isRetrying: timeline.isLoading,
              onRetry: () => ref.invalidate(channelTimelineProvider(key)),
            ),
          ),
        ),
        if (canPost)
          SimplePostBar(
            channelId: widget.channelId,
            channelName: widget.channelName,
            onPosted: () => ref.invalidate(channelTimelineProvider(key)),
          )
        else
          // ⚠ 投稿できないチャンネルではバーが出ず、下端の inset を誰も吸わない
          // ため、最後の投稿がナビゲーションバーのボタンに潜り込む (#1037)。
          // ここで高さだけ確保する。バーが出るときは SimplePostBar 側が吸う。
          const BottomSafeArea(child: SizedBox.shrink()),
      ],
    );
  }
}

class ChannelTimelineScreen extends ConsumerWidget {
  final String channelId;
  final String? channelName;

  const ChannelTimelineScreen({
    super.key,
    required this.channelId,
    this.channelName,
  });

  /// 操作のシートは、そのときの状態（フォロー中か等）を取ってから開く (#1051)。
  Future<void> _openActions(BuildContext context, WidgetRef ref) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChannelSupport) return;
    final messenger = ScaffoldMessenger.of(context);
    final Channel channel;
    try {
      channel = await (adapter as ChannelSupport).getChannel(channelId);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('チャンネルの取得に失敗しました')));
      return;
    }
    if (!context.mounted) return;
    await showChannelActions(context, ref, channel);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(channelName ?? 'チャンネル'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (ref.watch(currentAdapterProvider) is ChannelManagementSupport)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: 'チャンネルの操作',
              onPressed: () => _openActions(context, ref),
            ),
        ],
      ),
      body: ChannelTimelineView(channelId: channelId, channelName: channelName),
    );
  }
}
