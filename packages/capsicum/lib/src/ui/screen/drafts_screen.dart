import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../util/draft_display.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';

/// サーバー下書き一覧 (#174)。DraftSupport のあるアダプタ（Misskey）でのみ
/// ドロワーから辿れる。タップで compose に復元、ゴミ箱で削除する。
final _draftsProvider = FutureProvider.autoDispose<List<Draft>>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null || adapter is! DraftSupport) return [];
  return (adapter as DraftSupport).getDrafts();
});

class DraftsScreen extends ConsumerWidget {
  const DraftsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draftsAsync = ref.watch(_draftsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('下書き')),
      body: BottomSafeArea(
        child: draftsAsync.when(
          data: (drafts) {
            if (drafts.isEmpty) {
              return const Center(child: Text('下書きはありません'));
            }
            return ListView.separated(
              itemCount: drafts.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final draft = drafts[index];
                return _DraftTile(
                  draft: draft,
                  onTap: () => _restore(context, ref, draft),
                  onDelete: () => _confirmDelete(context, ref, draft),
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => RetryErrorView(
            message: '読み込みに失敗しました\n${summarizeOpError(error)}',
            isRetrying: draftsAsync.isLoading,
            onRetry: () => ref.invalidate(_draftsProvider),
          ),
        ),
      ),
    );
  }

  /// 下書きを compose に復元する。投稿 / 再保存で元下書きは削除されるため、
  /// 戻ってきたら一覧を再取得する。
  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    Draft draft,
  ) async {
    await context.push('/compose', extra: {'restoreDraft': draft});
    ref.invalidate(_draftsProvider);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Draft draft,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下書きの削除'),
        content: const Text('この下書きを削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! DraftSupport) return;
    try {
      await (adapter as DraftSupport).deleteDraft(draft.id);
      ref.invalidate(_draftsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('下書きを削除しました')));
      }
    } catch (e, st) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('削除に失敗しました')));
      }
      // 失敗率を host/backend で相関できるよう低頻度計装（#837）。ユーザーには
      // 上で SnackBar 通知済みなので赤ではない。
      reportOpFailure(
        tagKey: 'draft.op',
        operation: 'delete_server_draft',
        error: e,
        stackTrace: st,
        account: ref.accountForReport,
      );
    }
  }
}

class _DraftTile extends StatelessWidget {
  final Draft draft;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _DraftTile({
    required this.draft,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // 表記は compose のクイックチューザ (#963) と共有する。
    return ListTile(
      onTap: onTap,
      leading: const Icon(Icons.edit_note),
      title: Text(
        draftBodyPreview(draft),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(draftSubtitle(draft)),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: '削除',
        onPressed: onDelete,
      ),
    );
  }
}
