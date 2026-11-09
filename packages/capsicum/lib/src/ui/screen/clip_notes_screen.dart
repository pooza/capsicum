import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/clip_provider.dart';
import '../util/scroll_thresholds.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/clip_actions_sheet.dart';
import '../widget/post_tile.dart';
import '../widget/retry_error_view.dart';

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
    if (shouldLoadMore(_scrollController.position)) {
      ref.read(clipNotesProvider(widget.clipId).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(clipNotesProvider(widget.clipId));
    // 自分のクリップなら、操作（編集・削除）を出す (#1050)。⚠ 一覧に無い
    // （ほかの人の公開クリップ・まだ読めていない）ときは出さない。
    final canManage =
        ref.watch(currentAdapterProvider) is ClipManagementSupport;
    NoteClip? clip;
    for (final c
        in ref.watch(clipsProvider).valueOrNull ?? const <NoteClip>[]) {
      if (c.id == widget.clipId) clip = c;
    }

    return Scaffold(
      appBar: AppBar(
        // ⚠ 編集で名前を変えたら追随させる（一覧を取り直すので）。
        title: Text(clip?.name ?? widget.clipName ?? 'クリップ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (canManage && clip != null)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: 'クリップの操作',
              onPressed: () async {
                final deleted = await showClipActions(context, ref, clip!);
                if (deleted && context.mounted) Navigator.of(context).pop();
              },
            ),
        ],
      ),
      body: BottomSafeArea(
        child: timeline.when(
          data: (state) => state.posts.isEmpty
              ? const Center(child: Text('投稿がありません'))
              : RefreshIndicator(
                  onRefresh: () =>
                      ref.refresh(clipNotesProvider(widget.clipId).future),
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
          error: (error, stack) => RetryErrorView(
            message: '読み込みに失敗しました',
            isRetrying: timeline.isLoading,
            onRetry: () => ref.invalidate(clipNotesProvider(widget.clipId)),
          ),
        ),
      ),
    );
  }
}
