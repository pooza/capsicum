import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../widget/post_tile.dart';
import '../widget/simple_post_bar.dart';

class HashtagTimelineScreen extends ConsumerStatefulWidget {
  final String hashtag;

  const HashtagTimelineScreen({super.key, required this.hashtag});

  @override
  ConsumerState<HashtagTimelineScreen> createState() =>
      _HashtagTimelineScreenState();
}

class _HashtagTimelineScreenState extends ConsumerState<HashtagTimelineScreen> {
  final _scrollController = ScrollController();
  bool? _following;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFollowState();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadFollowState() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! HashtagSupport) return;
    try {
      final following =
          await (adapter as HashtagSupport).isFollowingHashtag(widget.hashtag);
      if (mounted) setState(() => _following = following);
    } catch (_) {
      // フォロー状態の取得に失敗しても画面表示は続行
    }
  }

  Future<void> _toggleFollow() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! HashtagSupport || _following == null) return;

    final hashtag = widget.hashtag;
    final support = adapter as HashtagSupport;
    try {
      if (_following!) {
        await support.unfollowHashtag(hashtag);
      } else {
        await support.followHashtag(hashtag);
      }
      if (mounted) setState(() => _following = !_following!);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作に失敗しました')),
        );
      }
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(hashtagTimelineProvider(widget.hashtag).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(hashtagTimelineProvider(widget.hashtag));

    return Scaffold(
      appBar: AppBar(
        title: Text('#${widget.hashtag}'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_following != null)
            IconButton(
              icon: Icon(
                _following! ? Icons.bookmark : Icons.bookmark_border,
              ),
              tooltip: _following! ? 'フォロー解除' : 'フォロー',
              onPressed: _toggleFollow,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: timeline.when(
              data: (state) => state.posts.isEmpty
                  ? const Center(child: Text('投稿がありません'))
                  : RefreshIndicator(
                      onRefresh: () => ref
                          .refresh(hashtagTimelineProvider(widget.hashtag).future),
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
                        onPressed: () => ref
                            .invalidate(hashtagTimelineProvider(widget.hashtag)),
                        child: const Text('再試行'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SimplePostBar(
            hashtag: widget.hashtag,
            onPosted: () =>
                ref.invalidate(hashtagTimelineProvider(widget.hashtag)),
          ),
        ],
      ),
    );
  }
}
