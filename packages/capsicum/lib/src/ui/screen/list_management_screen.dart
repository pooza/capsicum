import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/list_provider.dart';

class ListManagementScreen extends ConsumerWidget {
  const ListManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listsAsync = ref.watch(listsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('リスト管理'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新規作成',
            onPressed: () => _showCreateDialog(context, ref),
          ),
        ],
      ),
      body: listsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('読み込みに失敗しました: $e')),
        data: (lists) {
          if (lists.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.list, size: 48, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('リストがありません'),
                  SizedBox(height: 8),
                  Text(
                    '右上の＋ボタンからリストを作成できます',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            itemCount: lists.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final list = lists[index];
              return ListTile(
                leading: const Icon(Icons.list),
                title: Text(list.title),
                onTap: () => context.push('/lists/members', extra: list),
                trailing: IconButton(
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () => _showActionSheet(context, ref, list),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('リストを作成'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'リスト名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              final title = controller.text.trim();
              if (title.isEmpty) return;
              Navigator.pop(dialogContext);
              _createList(context, ref, title);
            },
            child: const Text('作成'),
          ),
        ],
      ),
    );
  }

  void _showActionSheet(BuildContext context, WidgetRef ref, PostList list) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.people),
              title: const Text('メンバー'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push('/lists/members', extra: list);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('名前を変更'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showRenameDialog(context, ref, list);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('削除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(sheetContext);
                _showDeleteDialog(context, ref, list);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, WidgetRef ref, PostList list) {
    final controller = TextEditingController(text: list.title);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('リスト名を変更'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'リスト名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              final title = controller.text.trim();
              if (title.isEmpty || title == list.title) return;
              Navigator.pop(dialogContext);
              _updateList(context, ref, list.id, title);
            },
            child: const Text('変更'),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, WidgetRef ref, PostList list) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('リストを削除'),
        content: Text('リスト「${list.title}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _deleteList(context, ref, list);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  Future<void> _createList(
    BuildContext context,
    WidgetRef ref,
    String title,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! ListSupport) return;
    try {
      await (adapter as ListSupport).createList(title);
      ref.invalidate(listsProvider);
      messenger.showSnackBar(SnackBar(content: Text('リスト「$title」を作成しました')));
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('リストの作成に失敗しました')));
    }
  }

  Future<void> _updateList(
    BuildContext context,
    WidgetRef ref,
    String id,
    String title,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! ListSupport) return;
    try {
      await (adapter as ListSupport).updateList(id, title);
      ref.invalidate(listsProvider);
      messenger.showSnackBar(SnackBar(content: Text('リスト名を「$title」に変更しました')));
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('リスト名の変更に失敗しました')));
    }
  }

  Future<void> _deleteList(
    BuildContext context,
    WidgetRef ref,
    PostList list,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! ListSupport) return;
    try {
      await (adapter as ListSupport).deleteList(list.id);
      ref.invalidate(listsProvider);
      messenger.showSnackBar(
        SnackBar(content: Text('リスト「${list.title}」を削除しました')),
      );
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('リストの削除に失敗しました')));
    }
  }
}
