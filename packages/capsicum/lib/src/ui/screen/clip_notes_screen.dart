import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/clip_provider.dart';
import '../widget/post_tile.dart';

class ClipNotesScreen extends ConsumerStatefulWidget {
  final String clipId;
  final String? clipName;

  const ClipNotesScreen({super.key, required this.clipId, this.clipName});

  @override
  ConsumerState<ClipNotesScreen> createState() => _ClipNotesScreenState();
}

class _ClipNotesScreenState extends ConsumerState<ClipNotesScreen> {
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
      ref.read(clipNotesProvider(widget.clipId).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(clipNotesProvider(widget.clipId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.clipName ?? 'クリップ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: timeline.when(
        data: (state) => state.posts.isEmpty
            ? const Center(child: Text('投稿がありません'))
            : RefreshIndicator(
                onRefresh: () =>
                    ref.refresh(clipNotesProvider(widget.clipId).future),
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
                      ref.invalidate(clipNotesProvider(widget.clipId)),
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
