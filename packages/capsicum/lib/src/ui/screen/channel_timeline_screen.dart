import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../widget/post_tile.dart';

class ChannelTimelineScreen extends ConsumerStatefulWidget {
  final String channelId;
  final String? channelName;

  const ChannelTimelineScreen({
    super.key,
    required this.channelId,
    this.channelName,
  });

  @override
  ConsumerState<ChannelTimelineScreen> createState() =>
      _ChannelTimelineScreenState();
}

class _ChannelTimelineScreenState extends ConsumerState<ChannelTimelineScreen> {
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
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(channelTimelineProvider(widget.channelId).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(channelTimelineProvider(widget.channelId));
    final adapter = ref.watch(currentAdapterProvider);
    final canPost = adapter is ChannelSupport;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.channelName ?? 'チャンネル'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      floatingActionButton: canPost
          ? FloatingActionButton(
              onPressed: () => context.push(
                '/compose',
                extra: {
                  'channelId': widget.channelId,
                  'channelName': widget.channelName,
                },
              ),
              child: const Icon(Icons.edit),
            )
          : null,
      body: timeline.when(
        data: (state) => state.posts.isEmpty
            ? const Center(child: Text('投稿がありません'))
            : RefreshIndicator(
                onRefresh: () => ref.refresh(
                  channelTimelineProvider(widget.channelId).future,
                ),
                child: ListView.separated(
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
                    return PostTile(post: state.posts[index]);
                  },
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('読み込みに失敗しました', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () =>
                      ref.invalidate(channelTimelineProvider(widget.channelId)),
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
