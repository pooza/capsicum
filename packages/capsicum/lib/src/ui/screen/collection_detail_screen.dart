import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/is_cat_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/user_acct.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/emoji_text.dart';
import '../widget/section_header.dart';
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

  /// 詳細を読み込む。成功したら true、失敗したら false を返す。
  /// 追加/削除後のリロード結果を呼び出し側が判別できるようにする（#806）。
  Future<bool> _load() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! CollectionsSupport) {
      // 対応しないサーバーではローディングを畳んで失敗表示に落とす
      // （放置すると無限スピナーになる。一覧画面と挙動を揃える）。
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
      return false;
    }
    try {
      final detail = await (adapter as CollectionsSupport).getCollection(
        widget.collectionId,
      );
      final accounts = await ref
          .read(isCatEnricherProvider)
          .enrichUsers(detail.accounts);
      if (!mounted) return true;
      setState(() {
        _detail = CollectionDetail(
          collection: detail.collection,
          accounts: accounts,
        );
        _loading = false;
        _failed = false;
      });
      return true;
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: 'load_detail',
        error: e,
        stackTrace: st,
        account: ref.accountForReport,
      );
      if (mounted) {
        setState(() {
          _loading = false;
          // 既に内容を表示できているときは、再読み込みの一時失敗で画面を
          // 失敗表示に落とさない（追加は成功しているのに裏が失敗表示になる
          // 食い違いを避ける。次のリフレッシュで自己回復する。#806）。
          if (_detail == null) _failed = true;
        });
      }
      return false;
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
      body: BottomSafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final detail = _detail;
    if (_failed || detail == null) {
      return const Center(child: Text('コレクションの読み込みに失敗しました'));
    }
    final theme = Theme.of(context);
    // API 仕様上 accounts の先頭が所有者、以降が items 由来のメンバー
    // （[object.account] + items.map(&:account)）。所有者が自分のコレクションに
    // 自分を入れると先頭とメンバーの両方に現れるため、作成者節は先頭 1 件のみ、
    // メンバー節は先頭以外（自分を入れていれば所有者も含む）で分ける。
    final ownerId = detail.collection.ownerAccountId;
    final accounts = detail.accounts;
    final ownerRow = accounts.isNotEmpty && accounts.first.id == ownerId
        ? accounts.first
        : null;
    // ownerRow を採れたら先頭を落とす。採れない（先頭が所有者でない異常時）は
    // id で除外してフォールバックする。
    final others = ownerRow != null
        ? accounts.sublist(1)
        : accounts.where((u) => u.id != ownerId).toList(growable: false);
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
          if (ownerRow != null) ...[
            const SectionHeader('作成者'),
            _memberTile(ownerRow, detail.collection),
          ],
          const SectionHeader('メンバー'),
          if (others.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text('メンバーはいません', style: TextStyle(color: Colors.grey)),
            )
          else
            // メンバー節に所有者が出る（自分を入れた）ときは作成者タグを付け、
            // 作成者節との重複が意図的だと分かるようにする。
            ...others.map(
              (user) =>
                  _memberTile(user, detail.collection, showOwnerTag: true),
            ),
        ],
      ),
    );
  }

  /// リスト内の区切り見出し（作成者 / メンバー）。
  Widget _memberTile(
    User user,
    Collection collection, {
    bool showOwnerTag = false,
  }) {
    final isOwnerAccount = user.id == collection.ownerAccountId;
    return ListTile(
      onTap: () => context.push('/profile', extra: user),
      leading: UserAvatar(user: user, size: 40),
      title: Row(
        children: [
          Flexible(
            child: EmojiText(
              user.displayName ?? user.username,
              emojis: user.emojis,
              fallbackHost: user.host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // メンバー節に所有者本人が現れるとき（自分を入れた）だけ作成者と
          // 明示し、作成者節との重複が意図的だと分かるようにする。
          if (showOwnerTag && isOwnerAccount) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '作成者',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        // ⚠ 自前の三項は host == '' を落とす (#1035-C4)。
        '@${userAcct(user)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // 所有者はメンバーを外せる。作成者が自分をメンバーに入れている場合
      // （メンバー節に作成者本人が出る = showOwnerTag）も、その item を外せる
      // ようにする（#808）。作成者節（先頭・showOwnerTag=false）の行には出さない。
      trailing: (_isOwner && (!isOwnerAccount || showOwnerTag))
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
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: 'revoke',
        error: e,
        stackTrace: st,
        account: ref.accountForReport,
      );
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
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: 'remove_member',
        error: e,
        stackTrace: st,
        account: ref.accountForReport,
      );
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
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: 'delete',
        error: e,
        stackTrace: st,
        account: ref.accountForReport,
      );
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
    final tagController = TextEditingController(text: collection.tagName ?? '');
    // トグルは現在値から prefill する（model は getCollection で discoverable /
    // sensitive を保持している）。null 時は作成ダイアログと同じ既定に倒す。
    var discoverable = collection.discoverable ?? true;
    var sensitive = collection.sensitive ?? false;
    try {
      final messenger = ScaffoldMessenger.of(context);
      final saved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('コレクションを編集'),
            content: SingleChildScrollView(
              child: Column(
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
                  TextField(
                    controller: tagController,
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
                    value: discoverable,
                    onChanged: (v) => setDialogState(() => discoverable = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('センシティブ'),
                    subtitle: const Text('閲覧注意として扱う'),
                    value: sensitive,
                    onChanged: (v) => setDialogState(() => sensitive = v),
                  ),
                ],
              ),
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
        ),
      );
      if (saved != true) return;
      final adapter = ref.read(currentAdapterProvider);
      if (adapter is! CollectionsSupport) return;
      try {
        final tag = tagController.text.trim();
        await (adapter as CollectionsSupport).updateCollection(
          widget.collectionId,
          name: nameController.text.trim(),
          description: descController.text.trim(),
          // 空は null で送らない（作成と同じ。既存タグのクリアは非対応）。
          tagName: tag.isEmpty ? null : tag,
          discoverable: discoverable,
          sensitive: sensitive,
        );
        await _load();
      } catch (e, st) {
        reportOpFailure(
          tagKey: 'collections.op',
          operation: 'update',
          error: e,
          stackTrace: st,
          account: ref.accountForReport,
        );
        messenger.showSnackBar(const SnackBar(content: Text('保存に失敗しました')));
      }
    } finally {
      nameController.dispose();
      descController.dispose();
      tagController.dispose();
    }
  }

  Future<void> _showAddMemberSheet() async {
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

    try {
      await showModalBottomSheet(
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
              // ⚠ キーボードとナビゲーションバーの両方を足す (#1062)。
              padding: EdgeInsets.only(
                bottom:
                    MediaQuery.viewInsetsOf(context).bottom +
                    MediaQuery.paddingOf(context).bottom,
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
                              // シートが閉じられた後の setState を避ける。
                              if (!context.mounted) return;
                              setSheetState(() {
                                results = r.users;
                                searching = false;
                              });
                            } catch (e, st) {
                              reportOpFailure(
                                tagKey: 'collections.op',
                                operation: 'search_member',
                                error: e,
                                stackTrace: st,
                                account: ref.accountForReport,
                              );
                              if (!context.mounted) return;
                              setSheetState(() {
                                searching = false;
                                feedback = '検索に失敗しました。';
                                feedbackIsError = true;
                              });
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
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer
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
                              // ⚠ 自前の三項は host == '' を落とす (#1035-C4)。
                              '@${userAcct(user)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: alreadyMember
                                ? const Icon(Icons.check, color: Colors.grey)
                                : IconButton(
                                    icon: const Icon(Icons.add),
                                    onPressed: () async {
                                      final r = await _addMember(user);
                                      // シートが閉じられた後の setState を避ける。
                                      if (!context.mounted) return;
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
    } finally {
      controller.dispose();
      searchFocus.dispose();
    }
  }

  /// メンバー追加を試み、シートに出す結果メッセージを返す。
  /// 追加不可（相手が featureable でない等）はサーバーが 403 を返すため、
  /// 定型文でなく理由の当たりを付けた文面にする（#722）。
  Future<({bool ok, String message})> _addMember(User user) async {
    final currentCount = _detail?.accounts.length ?? 0;
    // 所有者アカウントも accounts に含まれるためメンバー数は -1 で数える。
    if (currentCount - 1 >= _maxMembers) {
      return (ok: false, message: 'コレクションは最大$_maxMembersアカウントまでです。');
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
      // 追加は成功。直後のリロードが失敗しても操作自体は成功なので ok:true を
      // 返しつつ、一覧反映が遅れる旨を添える（緑「追加しました」の裏で画面が
      // 失敗表示になる食い違いは _load 側で解消済み。#806）。
      final reloaded = await _load();
      return (
        ok: true,
        message: reloaded
            ? '@${user.username} を追加しました。'
            : '@${user.username} を追加しました（一覧の反映は次の更新時）。',
      );
    } on DioException catch (e) {
      // 403/422 は相手側設定に起因する想定内の失敗のため Sentry には流さない。
      return (ok: false, message: _addMemberErrorMessage(e));
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: 'add_member',
        error: e,
        stackTrace: st,
        account: ref.accountForReport,
      );
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
