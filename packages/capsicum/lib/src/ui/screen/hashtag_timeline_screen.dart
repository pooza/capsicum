import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/hashtag_provider.dart';
import '../widget/post_tile.dart';

class HashtagTimelineScreen extends ConsumerStatefulWidget {
  final String hashtag;

  const HashtagTimelineScreen({super.key, required this.hashtag});

  @override
  ConsumerState<HashtagTimelineScreen> createState() =>
      _HashtagTimelineScreenState();
}

class _HashtagTimelineScreenState
    extends ConsumerState<HashtagTimelineScreen> {
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
      ),
      body: timeline.when(
        data: (state) => state.posts.isEmpty
            ? const Center(child: Text('投稿がありません'))
            : RefreshIndicator(
                onRefresh: () => ref.refresh(
                  hashtagTimelineProvider(widget.hashtag).future,
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
                  onPressed: () => ref.invalidate(
                    hashtagTimelineProvider(widget.hashtag),
                  ),
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
