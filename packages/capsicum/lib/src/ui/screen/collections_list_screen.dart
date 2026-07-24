import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../widget/account_multi_select_sheet.dart';

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
  bool _loadingMore = false;

  /// 次ページの offset (#802)。null なら続きなし（終端 or 未取得）。
  int? _nextOffset;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
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
      _loadMore();
    }
  }

  Future<CollectionPage> _fetchPage(
    CollectionsSupport support, {
    int? offset,
  }) => widget.inCollections
      ? support.getInCollections(widget.accountId, offset: offset)
      : support.getAccountCollections(widget.accountId, offset: offset);

  Future<void> _load() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) {
      setState(() => _loading = false);
      return;
    }
    try {
      final page = await _fetchPage(adapter as CollectionsSupport);
      if (mounted) {
        setState(() {
          _collections = page.collections;
          _nextOffset = page.nextOffset;
          _loading = false;
        });
      }
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: widget.inCollections ? 'load_in_list' : 'load_list',
        error: e,
        stackTrace: st,
        account: ref.read(currentAccountProvider),
      );
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final offset = _nextOffset;
    if (_loadingMore || _loading || offset == null) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetchPage(
        adapter as CollectionsSupport,
        offset: offset,
      );
      if (mounted) {
        setState(() {
          _collections = [...?_collections, ...page.collections];
          _nextOffset = page.nextOffset;
          _loadingMore = false;
        });
      }
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: widget.inCollections ? 'load_in_more' : 'load_more',
        error: e,
        stackTrace: st,
        account: ref.read(currentAccountProvider),
      );
      // 継続エラー時の自動再試行ストームを避けるため next offset を止める
      // （回復は pull-to-refresh で _load が再取得）。
      if (mounted) {
        setState(() {
          _nextOffset = null;
          _loadingMore = false;
        });
      }
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
        controller: _scrollController,
        // 末尾の loadMore スピナー行を 1 つ足す (#802)。
        itemCount: collections.length + (_loadingMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index >= collections.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
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
    final result =
        await showDialog<
          ({
            String name,
            String description,
            String tagName,
            bool discoverable,
            bool sensitive,
            List<User> members,
          })
        >(
          context: context,
          builder: (context) => const _CreateCollectionDialog(),
        );
    if (result == null) return;
    final name = result.name.trim();
    if (name.isEmpty) return;
    final description = result.description.trim();
    final tagName = result.tagName.trim();
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) return;
    try {
      // sensitive / discoverable はサーバー側で null 不可（既定値なし）のため
      // 明示送信する。未送信だと 422 で作成が失敗する（#722）。tag_name は任意で、
      // 空なら null（タグに束ねない）で送る（#801）。
      final collection = await (adapter as CollectionsSupport).createCollection(
        name: name,
        description: description.isEmpty ? null : description,
        tagName: tagName.isEmpty ? null : tagName,
        discoverable: result.discoverable,
        sensitive: result.sensitive,
        // 初期メンバーは作成時に一括登録する（createCollection の account_ids、
        // #866）。所有者はサーバーが自動で入れるため含めない。
        accountIds: result.members.map((u) => u.id).toList(),
      );
      if (!mounted) return;
      await _load();
      if (mounted) await context.push('/collection', extra: collection.id);
      if (mounted) _load();
    } on DioException catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: 'create',
        error: e,
        stackTrace: st,
        account: ref.read(currentAccountProvider),
      );
      messenger.showSnackBar(
        SnackBar(content: Text(_createErrorMessage(e.response?.statusCode))),
      );
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: 'create',
        error: e,
        stackTrace: st,
        account: ref.read(currentAccountProvider),
      );
      messenger.showSnackBar(const SnackBar(content: Text('作成に失敗しました')));
    }
  }

  /// 作成失敗の HTTP ステータスから理由の当たりを付けた文面にする（#806）。
  /// _addMemberErrorMessage と同じく、定型文でなくステータス別に案内する。
  String _createErrorMessage(int? status) {
    if (status == 422) {
      return 'コレクションを作成できませんでした（名前が不正、または上限に達しています）。';
    }
    if (status == 403) {
      return 'コレクションを作成する権限がありません。';
    }
    return 'コレクションの作成に失敗しました（通信エラー）。';
  }
}

/// コレクション作成ダイアログ。
///
/// macOS の `showDialog` では `autofocus: true` の TextField が
/// ダイアログ barrier の FocusScope と競合し、「A KeyDownEvent is dispatched,
/// but ... already pressed」の例外を毎キー打つたびに投げてキー入力を取りこぼす
/// （#722）。autofocus を使わず、初回フレーム後に FocusNode で明示フォーカスを
/// 要求してこのレースを避ける。
class _CreateCollectionDialog extends ConsumerStatefulWidget {
  const _CreateCollectionDialog();

  @override
  ConsumerState<_CreateCollectionDialog> createState() =>
      _CreateCollectionDialogState();
}

class _CreateCollectionDialogState
    extends ConsumerState<_CreateCollectionDialog> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _tagController = TextEditingController();
  final _nameFocus = FocusNode();
  bool _discoverable = true;
  bool _sensitive = false;

  /// 作成時に一括登録する初期メンバー (#866)。所有者はサーバーが自動で入れる。
  final List<User> _initialMembers = [];

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
    _tagController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(context, (
      name: _nameController.text,
      description: _descController.text,
      tagName: _tagController.text,
      discoverable: _discoverable,
      sensitive: _sensitive,
      members: _initialMembers,
    ));
  }

  Future<void> _pickMembers() async {
    // 所有者は作成時にサーバーが自動で入れるため、自分は候補から外す (#866)。
    final selfId = ref.read(currentAccountProvider)?.user.id;
    final selected = await showAccountMultiSelectSheet(
      context,
      initial: _initialMembers,
      excludeIds: {?selfId},
    );
    if (!mounted) return;
    if (selected != null) {
      setState(() {
        _initialMembers
          ..clear()
          ..addAll(selected);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('コレクションを作成'),
      content: SingleChildScrollView(
        child: Column(
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
            TextField(
              controller: _tagController,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'タグ名（任意）',
                hintText: 'コレクションを束ねるハッシュタグ',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('公開'),
              subtitle: const Text('一覧や検索に表示する'),
              value: _discoverable,
              onChanged: (v) => setState(() => _discoverable = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('センシティブ'),
              subtitle: const Text('閲覧注意として扱う'),
              value: _sensitive,
              onChanged: (v) => setState(() => _sensitive = v),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.group_add_outlined),
              title: const Text('初期メンバー（任意）'),
              subtitle: Text(
                _initialMembers.isEmpty
                    ? 'アカウントを検索して選ぶ'
                    : '${_initialMembers.length} アカウントを選択中',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickMembers,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        // 名前が空のときは作成を無効化する（無言で閉じる silent no-op を避け、
        // 押せない理由を可視化する。#806）。
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _nameController,
          builder: (context, value, _) => TextButton(
            onPressed: value.text.trim().isEmpty ? null : _submit,
            child: const Text('作成'),
          ),
        ),
      ],
    );
  }
}
