import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/list_provider.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/post_tile.dart';
import '../widget/retry_error_view.dart';

/// リストのタイムラインを独立画面で表示する（#805）。ドロワーの「リスト」
/// クイックチューザから選んだリストへ push される。antenna_notes_screen と同型。
/// リスト自体は home のタブとしても表示できる（tab 管理）が、ここはチューザから
/// 素早く飛ぶための行き先。
class ListTimelineScreen extends ConsumerStatefulWidget {
  final String listId;
  final String? listName;

  const ListTimelineScreen({super.key, required this.listId, this.listName});

  @override
  ConsumerState<ListTimelineScreen> createState() => _ListTimelineScreenState();
}

class _ListTimelineScreenState extends ConsumerState<ListTimelineScreen> {
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
      ref.read(listTimelineProvider(widget.listId).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(listTimelineProvider(widget.listId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.listName ?? 'リスト'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: BottomSafeArea(
        child: timeline.when(
          data: (state) => state.posts.isEmpty
              ? const Center(child: Text('投稿がありません'))
              : RefreshIndicator(
                  onRefresh: () =>
                      ref.refresh(listTimelineProvider(widget.listId).future),
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
            onRetry: () => ref.invalidate(listTimelineProvider(widget.listId)),
          ),
        ),
      ),
    );
  }
}
