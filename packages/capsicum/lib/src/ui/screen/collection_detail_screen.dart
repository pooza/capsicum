import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/is_cat_provider.dart';
import '../widget/emoji_text.dart';
import '../widget/user_avatar.dart';

/// Mastodon 4.6 Collections（#722 / #742）のコレクション詳細画面。
///
/// メンバーアカウントを一覧し、閲覧者の立場に応じて操作を出し分ける:
/// - 所有者: メンバー追加/削除・コレクション編集/削除
/// - 載せられた本人: opt-out（自分を外す = revoke）
class CollectionDetailScreen extends ConsumerStatefulWidget {
  final String collectionId;

  const CollectionDetailScreen({super.key, required this.collectionId});

  @override
  ConsumerState<CollectionDetailScreen> createState() =>
      _CollectionDetailScreenState();
}

class _CollectionDetailScreenState
    extends ConsumerState<CollectionDetailScreen> {
  static const _maxMembers = 25;

  CollectionDetail? _detail;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) return;
    try {
      final detail = await (adapter as CollectionsSupport).getCollection(
        widget.collectionId,
      );
      final accounts = await ref
          .read(isCatEnricherProvider)
          .enrichUsers(detail.accounts);
      if (!mounted) return;
      setState(() {
        _detail = CollectionDetail(
          collection: detail.collection,
          accounts: accounts,
        );
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  String? get _myAccountId => ref.read(currentAccountProvider)?.user.id;

  bool get _isOwner {
    final owner = _detail?.collection.ownerAccountId;
    return owner != null && owner == _myAccountId;
  }

  /// 閲覧者自身がこのコレクションに載っている場合の item（revoke 対象）。
  CollectionItem? get _myItem {
    final me = _myAccountId;
    if (me == null || _isOwner) return null;
    for (final item in _detail?.collection.items ?? const <CollectionItem>[]) {
      if (item.accountId == me &&
          (item.state == CollectionItemState.accepted ||
              item.state == CollectionItemState.pending)) {
        return item;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.collection.name ?? 'コレクション'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (detail != null && _isOwner) ...[
            IconButton(
              icon: const Icon(Icons.person_add),
              tooltip: 'メンバーを追加',
              onPressed: _showAddMemberSheet,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') _showEditDialog();
                if (v == 'delete') _confirmDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('編集')),
                PopupMenuItem(value: 'delete', child: Text('削除')),
              ],
            ),
          ],
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final detail = _detail;
    if (_failed || detail == null) {
      return const Center(child: Text('コレクションの読み込みに失敗しました'));
    }
    final theme = Theme.of(context);
    // 先頭は所有者アカウント（CollectionWithAccounts の仕様）。作成者と
    // メンバーを見出しで分けて区別できるようにする。
    final ownerId = detail.collection.ownerAccountId;
    final owner = detail.accounts
        .where((u) => u.id == ownerId)
        .toList(growable: false);
    final others = detail.accounts
        .where((u) => u.id != ownerId)
        .toList(growable: false);
    final myItem = _myItem;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          if (detail.collection.description?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(detail.collection.description!),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '${others.length} アカウント',
              style: theme.textTheme.labelMedium,
            ),
          ),
          if (myItem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.person_remove_outlined),
                label: const Text('このコレクションから外れる'),
                onPressed: () => _confirmRevoke(myItem),
              ),
            ),
          if (owner.isNotEmpty) ...[
            _sectionHeader(theme, '作成者'),
            ...owner.map((user) => _memberTile(user, detail.collection)),
          ],
          _sectionHeader(theme, 'メンバー'),
          if (others.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text('メンバーはいません', style: TextStyle(color: Colors.grey)),
            )
          else
            ...others.map((user) => _memberTile(user, detail.collection)),
        ],
      ),
    );
  }

  /// リスト内の区切り見出し（作成者 / メンバー）。
  Widget _sectionHeader(ThemeData theme, String label) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _memberTile(User user, Collection collection) {
    final isOwnerAccount = user.id == collection.ownerAccountId;
    return ListTile(
      onTap: () => context.push('/profile', extra: user),
      leading: UserAvatar(user: user, size: 40),
      title: EmojiText(
        user.displayName ?? user.username,
        emojis: user.emojis,
        fallbackHost: user.host,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '@${user.username}${user.host != null ? '@${user.host}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // 所有者はメンバー（自分以外）を削除できる。
      trailing: (_isOwner && !isOwnerAccount)
          ? IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
              tooltip: '外す',
              onPressed: () => _removeMember(user),
            )
          : null,
    );
  }

  /// メンバーの item id を現在の詳細から引く（削除に使う）。
  String? _itemIdForAccount(String accountId) {
    for (final item in _detail?.collection.items ?? const <CollectionItem>[]) {
      if (item.accountId == accountId) return item.id;
    }
    return null;
  }

  Future<void> _confirmRevoke(CollectionItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('コレクションから外れる'),
        content: const Text('このコレクションから自分を外しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('外れる'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) return;
    try {
      await (adapter as CollectionsSupport).revokeCollectionItem(
        widget.collectionId,
        item.id,
      );
      messenger.showSnackBar(const SnackBar(content: Text('コレクションから外れました')));
      await _load();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('操作に失敗しました')));
    }
  }

  Future<void> _removeMember(User user) async {
    final messenger = ScaffoldMessenger.of(context);
    final itemId = _itemIdForAccount(user.id);
    if (itemId == null) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) return;
    try {
      await (adapter as CollectionsSupport).removeCollectionItem(
        widget.collectionId,
        itemId,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('@${user.username} を外しました')),
      );
      await _load();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('メンバーの削除に失敗しました')));
    }
  }

  Future<void> _confirmDelete() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('コレクションを削除'),
        content: Text('「${_detail?.collection.name}」を削除しますか？'),
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
    if (ok != true) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) return;
    try {
      await (adapter as CollectionsSupport).deleteCollection(
        widget.collectionId,
      );
      messenger.showSnackBar(const SnackBar(content: Text('コレクションを削除しました')));
      navigator.pop();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('削除に失敗しました')));
    }
  }

  Future<void> _showEditDialog() async {
    final collection = _detail?.collection;
    if (collection == null) return;
    final nameController = TextEditingController(text: collection.name);
    final descController = TextEditingController(
      text: collection.description ?? '',
    );
    final messenger = ScaffoldMessenger.of(context);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('コレクションを編集'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '名前'),
            ),
            TextField(
              controller: descController,
              decoration: const InputDecoration(labelText: '説明'),
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
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) return;
    try {
      await (adapter as CollectionsSupport).updateCollection(
        widget.collectionId,
        name: nameController.text.trim(),
        description: descController.text.trim(),
      );
      await _load();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('保存に失敗しました')));
    }
  }

  void _showAddMemberSheet() {
    final controller = TextEditingController();
    // macOS の modal では autofocus が barrier の FocusScope と競合し
    // キー入力を取りこぼす（#722 と同型）。autofocus せず初回フレーム後に
    // FocusNode で明示フォーカスを要求する。
    final searchFocus = FocusNode();
    var focusRequested = false;
    List<User> results = [];
    bool searching = false;
    // 追加結果はシート内に表示する。SnackBar はボトムシートの裏に隠れて
    // 見えないため（#722）。
    String? feedback;
    bool feedbackIsError = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        if (!focusRequested) {
          focusRequested = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (searchFocus.context != null) searchFocus.requestFocus();
          });
        }
        return StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: controller,
                      focusNode: searchFocus,
                      decoration: InputDecoration(
                        hintText: 'アカウントを検索',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                      ),
                      onSubmitted: (query) async {
                        if (query.trim().isEmpty) return;
                        setSheetState(() {
                          searching = true;
                          feedback = null;
                        });
                        final adapter = ref.read(currentAdapterProvider);
                        if (adapter is SearchSupport) {
                          try {
                            final r = await (adapter as SearchSupport).search(
                              query.trim(),
                            );
                            setSheetState(() {
                              results = r.users;
                              searching = false;
                            });
                          } catch (_) {
                            setSheetState(() => searching = false);
                          }
                        }
                      },
                    ),
                  ),
                  if (feedback != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      color: feedbackIsError
                          ? Theme.of(context).colorScheme.errorContainer
                          : Theme.of(context).colorScheme.secondaryContainer,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            feedbackIsError
                                ? Icons.error_outline
                                : Icons.check_circle_outline,
                            size: 18,
                            color: feedbackIsError
                                ? Theme.of(context).colorScheme.onErrorContainer
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              feedback!,
                              style: TextStyle(
                                color: feedbackIsError
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.onErrorContainer
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: results.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final user = results[index];
                        final alreadyMember =
                            _detail?.accounts.any((m) => m.id == user.id) ??
                            false;
                        return ListTile(
                          leading: UserAvatar(user: user, size: 40),
                          title: EmojiText(
                            user.displayName ?? user.username,
                            emojis: user.emojis,
                            fallbackHost: user.host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '@${user.username}${user.host != null ? '@${user.host}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: alreadyMember
                              ? const Icon(Icons.check, color: Colors.grey)
                              : IconButton(
                                  icon: const Icon(Icons.add),
                                  onPressed: () async {
                                    final r = await _addMember(user);
                                    setSheetState(() {
                                      feedback = r.message;
                                      feedbackIsError = !r.ok;
                                    });
                                  },
                                ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// メンバー追加を試み、シートに出す結果メッセージを返す。
  /// 追加不可（相手が featureable でない等）はサーバーが 403 を返すため、
  /// 定型文でなく理由の当たりを付けた文面にする（#722）。
  Future<({bool ok, String message})> _addMember(User user) async {
    final currentCount = _detail?.accounts.length ?? 0;
    // 所有者アカウントも accounts に含まれるためメンバー数は -1 で数える。
    if (currentCount - 1 >= _maxMembers) {
      return (ok: false, message: 'コレクションは最大25アカウントまでです。');
    }
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) {
      return (ok: false, message: 'この操作はこのサーバーでは使えません。');
    }
    try {
      await (adapter as CollectionsSupport).addCollectionItem(
        widget.collectionId,
        user.id,
      );
      await _load();
      return (ok: true, message: '@${user.username} を追加しました。');
    } on DioException catch (e) {
      return (ok: false, message: _addMemberErrorMessage(e));
    } catch (_) {
      return (ok: false, message: 'メンバーの追加に失敗しました。');
    }
  }

  /// 追加失敗の HTTP ステータスから、相手側の設定に起因する不可を案内する。
  /// 403 は「相手がコレクションに載ることを許可していない」= サーバーの
  /// featureable_by? 判定（公開・鍵/フォロー・ブロック関係・4.6 の承認方針）。
  String _addMemberErrorMessage(DioException e) {
    final status = e.response?.statusCode;
    if (status == 403) {
      return 'この相手はコレクションに追加できません。\n'
          '相手のプロフィールが非公開（ディレクトリ非掲載）、'
          '鍵アカウントで承認済みフォロワーでない、'
          'または相手側の承認設定・ブロック関係のためです。相手の設定によります。';
    }
    if (status == 422) {
      return 'このアカウントは追加できません（すでにメンバー、または対象が不正です）。';
    }
    return 'メンバーの追加に失敗しました（通信エラー）。';
  }
}
