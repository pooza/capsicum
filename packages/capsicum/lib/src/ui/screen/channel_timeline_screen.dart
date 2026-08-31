import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/post_tile.dart';
import '../widget/retry_error_view.dart';
import '../widget/simple_post_bar.dart';

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
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 600) {
      // 継続エラー時 (loadMoreError) は自動再試行を止める (#678)。isLoadingMore /
      // hasMore は loadMore 側でも弾くが、リトライストーム抑止のため loadMoreError
      // はトリガー段で見る。回復は pull-to-refresh で build() 再実行時。
      final state = ref
          .read(channelTimelineProvider(widget.channelId))
          .valueOrNull;
      if (state != null && state.loadMoreError != null) return;
      ref.read(channelTimelineProvider(widget.channelId).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(channelTimelineProvider(widget.channelId));
    final adapter = ref.watch(currentAdapterProvider);
    final canPost = adapter is ChannelSupport;

    return Column(
      children: [
        Expanded(
          child: timeline.when(
            data: (state) => state.posts.isEmpty
                ? const Center(child: Text('投稿がありません'))
                : RefreshIndicator(
                    onRefresh: () => ref.refresh(
                      channelTimelineProvider(widget.channelId).future,
                    ),
                    child: ListView.separated(
                      controller: _scrollController,
                      itemCount:
                          state.posts.length + (state.isLoadingMore ? 1 : 0),
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index >= state.posts.length) {
                          return const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator()),
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
              onRetry: () =>
                  ref.invalidate(channelTimelineProvider(widget.channelId)),
            ),
          ),
        ),
        if (canPost)
          SimplePostBar(
            channelId: widget.channelId,
            channelName: widget.channelName,
            onPosted: () =>
                ref.invalidate(channelTimelineProvider(widget.channelId)),
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

class ChannelTimelineScreen extends StatelessWidget {
  final String channelId;
  final String? channelName;

  const ChannelTimelineScreen({
    super.key,
    required this.channelId,
    this.channelName,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(channelName ?? 'チャンネル'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ChannelTimelineView(channelId: channelId, channelName: channelName),
    );
  }
}
