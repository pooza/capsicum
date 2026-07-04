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
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<({String name, String description})>(
      context: context,
      builder: (context) => const _CreateCollectionDialog(),
    );
    if (result == null) return;
    final name = result.name.trim();
    if (name.isEmpty) return;
    final description = result.description.trim();
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) return;
    try {
      final collection = await (adapter as CollectionsSupport).createCollection(
        name: name,
        description: description.isEmpty ? null : description,
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

/// コレクション作成ダイアログ。
///
/// macOS の `showDialog` では `autofocus: true` の TextField が
/// ダイアログ barrier の FocusScope と競合し、「A KeyDownEvent is dispatched,
/// but ... already pressed」の例外を毎キー打つたびに投げてキー入力を取りこぼす
/// （#722）。autofocus を使わず、初回フレーム後に FocusNode で明示フォーカスを
/// 要求してこのレースを避ける。
class _CreateCollectionDialog extends StatefulWidget {
  const _CreateCollectionDialog();

  @override
  State<_CreateCollectionDialog> createState() =>
      _CreateCollectionDialogState();
}

class _CreateCollectionDialogState extends State<_CreateCollectionDialog> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _nameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // ダイアログが完全に構築され barrier の FocusScope が確定してから
    // フォーカスを渡す（autofocus のレースを避ける）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(
      context,
      (name: _nameController.text, description: _descController.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('コレクションを作成'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            focusNode: _nameFocus,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: '名前'),
          ),
          TextField(
            controller: _descController,
            decoration: const InputDecoration(labelText: '説明（任意）'),
            maxLines: 3,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(onPressed: _submit, child: const Text('作成')),
      ],
    );
  }
}
