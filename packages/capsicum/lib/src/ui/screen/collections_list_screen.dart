import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';

/// Mastodon 4.6 Collections（#722 / #742）の一覧画面。
///
/// - [inCollections] false: [accountId] が**所有する**コレクション一覧
/// - [inCollections] true : [accountId] が**載せられている**コレクション一覧
/// [ownerView] が true（自分の所有一覧）のときは作成 FAB を出す。
class CollectionsListScreen extends ConsumerStatefulWidget {
  final String accountId;
  final bool inCollections;
  final bool ownerView;
  final String title;

  const CollectionsListScreen({
    super.key,
    required this.accountId,
    required this.inCollections,
    required this.ownerView,
    required this.title,
  });

  @override
  ConsumerState<CollectionsListScreen> createState() =>
      _CollectionsListScreenState();
}

class _CollectionsListScreenState extends ConsumerState<CollectionsListScreen> {
  List<Collection>? _collections;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) {
      setState(() => _loading = false);
      return;
    }
    try {
      final support = adapter as CollectionsSupport;
      final list = widget.inCollections
          ? await support.getInCollections(widget.accountId)
          : await support.getAccountCollections(widget.accountId);
      if (mounted) {
        setState(() {
          _collections = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      floatingActionButton: widget.ownerView
          ? FloatingActionButton(
              onPressed: _showCreateDialog,
              tooltip: 'コレクションを作成',
              child: const Icon(Icons.add),
            )
          : null,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final collections = _collections;
    if (collections == null) {
      return const Center(child: Text('コレクションの読み込みに失敗しました'));
    }
    if (collections.isEmpty) {
      return Center(
        child: Text(
          widget.inCollections ? '載せられているコレクションはありません' : 'コレクションはありません',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: collections.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final c = collections[index];
          return ListTile(
            leading: const Icon(Icons.collections_bookmark_outlined),
            title: Text(c.name),
            subtitle: c.description?.isNotEmpty == true
                ? Text(
                    c.description!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            trailing: c.itemCount != null ? Text('${c.itemCount}') : null,
            onTap: () async {
              await context.push('/collection', extra: c.id);
              if (mounted) _load();
            },
          );
        },
      ),
    );
  }

  Future<void> _showCreateDialog() async {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('コレクションを作成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名前'),
            ),
            TextField(
              controller: descController,
              decoration: const InputDecoration(labelText: '説明（任意）'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('作成'),
          ),
        ],
      ),
    );
    if (created != true) return;
    final name = nameController.text.trim();
    if (name.isEmpty) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) return;
    try {
      final collection = await (adapter as CollectionsSupport).createCollection(
        name: name,
        description: descController.text.trim().isEmpty
            ? null
            : descController.text.trim(),
      );
      if (!mounted) return;
      await _load();
      if (mounted) await context.push('/collection', extra: collection.id);
      if (mounted) _load();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('作成に失敗しました')));
    }
  }
}
