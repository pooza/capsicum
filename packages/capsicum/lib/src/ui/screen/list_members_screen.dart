import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../widget/emoji_text.dart';
import '../widget/user_avatar.dart';

class ListMembersScreen extends ConsumerStatefulWidget {
  final PostList postList;

  const ListMembersScreen({super.key, required this.postList});

  @override
  ConsumerState<ListMembersScreen> createState() => _ListMembersScreenState();
}

class _ListMembersScreenState extends ConsumerState<ListMembersScreen> {
  List<User>? _members;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! ListSupport) return;
    try {
      final members = await (adapter as ListSupport).getListAccounts(
        widget.postList.id,
      );
      if (mounted) {
        setState(() {
          _members = members;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.postList.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'メンバーを追加',
            onPressed: () => _showAddMemberDialog(context),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final members = _members;
    if (members == null) {
      return const Center(child: Text('メンバーの読み込みに失敗しました'));
    }
    if (members.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('メンバーがいません'),
            SizedBox(height: 8),
            Text('右上のボタンからメンバーを追加できます', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: members.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final user = members[index];
        return ListTile(
          leading: _buildAvatar(context, user),
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
          trailing: IconButton(
            icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
            tooltip: '削除',
            onPressed: () => _removeMember(user),
          ),
        );
      },
    );
  }

  Widget _buildAvatar(BuildContext context, User user) {
    return UserAvatar(user: user, size: 40);
  }

  Future<void> _removeMember(User user) async {
    final messenger = ScaffoldMessenger.of(context);
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! ListSupport) return;
    try {
      await (adapter as ListSupport).removeListAccounts(widget.postList.id, [
        user.id,
      ]);
      messenger.showSnackBar(
        SnackBar(content: Text('@${user.username} を削除しました')),
      );
      _loadMembers();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('メンバーの削除に失敗しました')));
    }
  }

  void _showAddMemberDialog(BuildContext context) {
    final controller = TextEditingController();
    List<User> results = [];
    bool searching = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
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
                    autofocus: true,
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
                      setSheetState(() => searching = true);
                      final adapter = ref.read(currentAdapterProvider);
                      if (adapter is SearchSupport) {
                        try {
                          final searchResults = await (adapter as SearchSupport)
                              .search(query.trim());
                          setSheetState(() {
                            results = searchResults.users;
                            searching = false;
                          });
                        } catch (_) {
                          setSheetState(() => searching = false);
                        }
                      }
                    },
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final user = results[index];
                      final alreadyMember =
                          _members?.any((m) => m.id == user.id) ?? false;
                      return ListTile(
                        leading: _buildAvatar(context, user),
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
                                onPressed: () =>
                                    _addMember(user, setSheetState),
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _addMember(
    User user,
    void Function(void Function()) setSheetState,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! ListSupport) return;
    try {
      await (adapter as ListSupport).addListAccounts(widget.postList.id, [
        user.id,
      ]);
      messenger.showSnackBar(
        SnackBar(content: Text('@${user.username} を追加しました')),
      );
      await _loadMembers();
      setSheetState(() {});
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('メンバーの追加に失敗しました')));
    }
  }
}
