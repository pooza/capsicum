import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/chat_provider.dart';
import '../util/chat_error.dart';
import '../widget/user_avatar.dart';

/// ルームに招待するユーザーを検索 → 招待を送信する画面 (#438)。owner のみ
/// 到達可能な前提だが、サーバー側で権限チェックされるためクライアント側で
/// owner ガードはしない (権限エラーは catch して SnackBar)。
class ChatRoomInviteScreen extends ConsumerStatefulWidget {
  final ChatRoom room;

  const ChatRoomInviteScreen({super.key, required this.room});

  @override
  ConsumerState<ChatRoomInviteScreen> createState() =>
      _ChatRoomInviteScreenState();
}

class _ChatRoomInviteScreenState extends ConsumerState<ChatRoomInviteScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  final Set<String> _invitedUserIds = {};
  String? _pendingUserId;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _query = value);
    });
  }

  Future<void> _invite(User user) async {
    if (_pendingUserId != null) return;
    setState(() => _pendingUserId = user.id);
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return;
    try {
      await (adapter as ChatSupport).inviteToRoom(
        roomId: widget.room.id,
        userId: user.id,
      );
      if (!mounted) return;
      setState(() => _invitedUserIds.add(user.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${user.displayName?.isNotEmpty == true ? user.displayName! : user.username} を招待しました',
          ),
        ),
      );
    } catch (e, st) {
      reportChatOpFailure('invite_to_room', e, st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('招待に失敗しました (${summarizeChatError(e)})')),
      );
    } finally {
      if (mounted) setState(() => _pendingUserId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _query.trim().isEmpty
        ? const AsyncValue<List<User>>.data([])
        : ref.watch(chatUserSearchProvider(_query.trim()));
    return Scaffold(
      appBar: AppBar(
        title: const Text('メンバーを招待'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                hintText: 'ユーザー名で検索',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: results.when(
              data: (users) {
                if (_query.trim().isEmpty) {
                  return const Center(child: Text('ユーザー名を入力してください'));
                }
                if (users.isEmpty) {
                  return const Center(child: Text('該当ユーザーがいません'));
                }
                return ListView.separated(
                  itemCount: users.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final user = users[index];
                    final invited = _invitedUserIds.contains(user.id);
                    final pending = _pendingUserId == user.id;
                    return _UserTile(
                      user: user,
                      invited: invited,
                      pending: pending,
                      onInvite: () => _invite(user),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    '検索に失敗しました\n${summarizeChatError(error)}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  final User user;
  final bool invited;
  final bool pending;
  final VoidCallback onInvite;

  const _UserTile({
    required this.user,
    required this.invited,
    required this.pending,
    required this.onInvite,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = user.displayName?.isNotEmpty == true
        ? user.displayName!
        : user.username;
    final handle = user.host != null
        ? '@${user.username}@${user.host}'
        : '@${user.username}';
    return ListTile(
      leading: UserAvatar(user: user, size: 40),
      title: Text(
        displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        handle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: invited
          ? const Chip(label: Text('招待済'))
          : pending
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : FilledButton.tonal(
                  onPressed: onInvite,
                  child: const Text('招待'),
                ),
    );
  }
}
