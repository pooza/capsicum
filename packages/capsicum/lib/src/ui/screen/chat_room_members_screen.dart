import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/chat_provider.dart';
import '../util/op_error.dart';
import '../widget/retry_error_view.dart';
import '../widget/user_avatar.dart';

/// 指定ルームのメンバー一覧 (#438)。owner は招待ボタンも表示される。
/// メンバーをタップすると相手のプロフィール画面へ。
class ChatRoomMembersScreen extends ConsumerWidget {
  final ChatRoom room;

  const ChatRoomMembersScreen({super.key, required this.room});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(chatRoomMembersProvider(room.id));
    final myUserId = ref.watch(currentAccountProvider)?.user.id;
    final isOwner = myUserId != null && room.ownerId == myUserId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('メンバー'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (isOwner)
            IconButton(
              icon: const Icon(Icons.person_add),
              tooltip: '招待',
              onPressed: () =>
                  context.push('/chat/room/${room.id}/invite', extra: room),
            ),
        ],
      ),
      body: members.when(
        data: (list) {
          return RefreshIndicator(
            onRefresh: () =>
                ref.refresh(chatRoomMembersProvider(room.id).future),
            child: list.isEmpty
                ? ListView(
                    // 空のときも overscroll で pull-to-refresh できるよう
                    // AlwaysScrollableScrollPhysics を指定する。
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 160),
                      Center(child: Text('メンバーがいません')),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final user = list[index].user;
                      if (user == null) {
                        return ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.person),
                          ),
                          title: Text('? (userId=${list[index].userId})'),
                        );
                      }
                      final displayName = user.displayName?.isNotEmpty == true
                          ? user.displayName!
                          : user.username;
                      final handle = user.host != null
                          ? '@${user.username}@${user.host}'
                          : '@${user.username}';
                      final isThisOwner = user.id == room.ownerId;
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
                        trailing: isThisOwner
                            ? Chip(
                                label: const Text('オーナー'),
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primaryContainer,
                              )
                            : null,
                        onTap: () => context.push('/profile', extra: user),
                      );
                    },
                  ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => RetryErrorView(
          message: '読み込みに失敗しました\n${summarizeOpError(error)}',
          selectable: true,
          isRetrying: members.isLoading,
          onRetry: () => ref.invalidate(chatRoomMembersProvider(room.id)),
        ),
      ),
    );
  }
}
