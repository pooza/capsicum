import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/list_provider.dart';
import '../util/scroll_thresholds.dart';
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
  final _nearTopTracker = NearTopTracker();

  ListTimelineKey get _key =>
      (account: ref.read(currentAccountKeyProvider), id: widget.listId);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // ⚠ **開いた時点で「先頭に居る」と名乗る** (#1235)。同じ TL を見ている別の
    // 画面（デッキのカラム等）が離れた位置のまま残していると、こちらが先頭に
    // 居ても新着が未表示バッファへ入り続ける。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(listTimelineProvider(_key).notifier).setNearTop(true);
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
    // 先頭へ戻ると notifier がまとめて取り込む。
    _nearTopTracker.update(
      _scrollController.position,
      (nearTop) =>
          ref.read(listTimelineProvider(_key).notifier).setNearTop(nearTop),
    );
    if (shouldLoadMore(_scrollController.position)) {
      ref.read(listTimelineProvider(_key).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ListTimelineKey key = (
      account: ref.watch(currentAccountKeyProvider),
      id: widget.listId,
    );
    final timeline = ref.watch(listTimelineProvider(key));

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
                      ref.refresh(listTimelineProvider(key).future),
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
            onRetry: () => ref.invalidate(listTimelineProvider(key)),
          ),
        ),
      ),
    );
  }
}
