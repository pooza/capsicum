import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/antenna_provider.dart';
import '../util/op_error.dart';
import '../util/scroll_thresholds.dart';
import '../widget/antenna_actions_sheet.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/post_tile.dart';
import '../widget/retry_error_view.dart';

class AntennaNotesScreen extends ConsumerStatefulWidget {
  final String antennaId;
  final String? antennaName;

  const AntennaNotesScreen({
    super.key,
    required this.antennaId,
    this.antennaName,
  });

  @override
  ConsumerState<AntennaNotesScreen> createState() => _AntennaNotesScreenState();
}

class _AntennaNotesScreenState extends ConsumerState<AntennaNotesScreen> {
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

  /// ⚠ 開いた経路は名前しか運ばないので、条件は一覧から引き直す（編集の初期値に
  /// 要る）。
  Future<void> _openActions() async {
    final messenger = ScaffoldMessenger.of(context);
    final List<Antenna> antennas;
    try {
      antennas = await ref.read(antennasProvider.future);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('アンテナを読み込めませんでした\n${summarizeOpError(e)}')),
      );
      return;
    }
    final antenna = antennas.where((a) => a.id == widget.antennaId).firstOrNull;
    if (!mounted) return;
    if (antenna == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('このアンテナは見つかりませんでした')),
      );
      return;
    }
    final deleted = await showAntennaActions(context, ref, antenna);
    if (deleted && mounted) Navigator.of(context).maybePop();
  }

  void _onScroll() {
    if (shouldLoadMore(_scrollController.position)) {
      ref.read(antennaNotesProvider(widget.antennaId).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(antennaNotesProvider(widget.antennaId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.antennaName ?? 'アンテナ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // 管理画面の行と同じシート (#1052・「閲覧のみの族の型」)。
          if (ref.watch(currentAdapterProvider) is AntennaManagementSupport)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: 'アンテナの操作',
              onPressed: _openActions,
            ),
        ],
      ),
      body: BottomSafeArea(
        child: timeline.when(
          data: (state) => state.posts.isEmpty
              ? const Center(child: Text('投稿がありません'))
              : RefreshIndicator(
                  onRefresh: () => ref.refresh(
                    antennaNotesProvider(widget.antennaId).future,
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
                      return PostTile(post: state.posts[index]);
                    },
                  ),
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => RetryErrorView(
            message: '読み込みに失敗しました',
            isRetrying: timeline.isLoading,
            onRetry: () =>
                ref.invalidate(antennaNotesProvider(widget.antennaId)),
          ),
        ),
      ),
    );
  }
}
