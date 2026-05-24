import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/chat_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../util/oauth_scope_error.dart';
import '../util/chat_error.dart';
import '../widget/oauth_scope_error_view.dart';
import '../widget/user_avatar.dart';

class ChatThreadListScreen extends ConsumerWidget {
  const ChatThreadListScreen({super.key});

  Future<void> _showNewMenu(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('新しいメッセージ'),
              subtitle: const Text('特定の相手に DM を送る'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.push('/chat/new');
              },
            ),
            ListTile(
              leading: const Icon(Icons.groups),
              title: const Text('新しいルーム'),
              subtitle: const Text('グループチャットを作る'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.push('/chat/room/new');
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threads = ref.watch(chatThreadListProvider);
    final invitations = ref.watch(chatInvitationInboxProvider);
    final invitationCount = invitations.maybeWhen(
      data: (list) => list.length,
      orElse: () => 0,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('メッセージ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'ルーム招待',
            onPressed: () => context.push('/chat/invitations'),
            icon: invitationCount > 0
                ? Badge(
                    label: Text(invitationCount.toString()),
                    child: const Icon(Icons.mail),
                  )
                : const Icon(Icons.mail_outline),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showNewMenu(context),
        tooltip: '新規',
        child: const Icon(Icons.add),
      ),
      body: threads.when(
        data: (list) => list.isEmpty
            ? const Center(child: Text('メッセージはありません'))
            : RefreshIndicator(
                onRefresh: () => ref.refresh(chatThreadListProvider.future),
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _ChatThreadTile(thread: list[index]),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => isOAuthScopeError(error)
            ? const OAuthScopeErrorView()
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText(
                        '読み込みに失敗しました\n${summarizeChatError(error)}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () => ref.invalidate(chatThreadListProvider),
                        child: const Text('再試行'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _ChatThreadTile extends ConsumerWidget {
  final ChatThread thread;

  const _ChatThreadTile({required this.thread});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = _previewText(thread.lastMessage);
    // DM とルーム (#438) を同一履歴画面に出すため、isRoom / isDm で leading・
    // title・遷移先を分岐する。Misskey 側 WebUI と同じ並べ方。
    if (thread.isRoom) {
      final room = thread.room!;
      return ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            Icons.groups,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: Text(
          room.name.isNotEmpty ? room.name : '(無題のルーム)',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: thread.isUnread ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(
          // ルームは発信者が毎メッセージ変わるので、先頭に発信者名を補う。
          '${_senderShortName(thread.lastMessage)}: $preview',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: _ThreadMetaColumn(thread: thread, ref: ref),
        onTap: () => context.push('/chat/room/${room.id}', extra: room),
      );
    }
    final otherUser = thread.otherUser!;
    return ListTile(
      leading: UserAvatar(user: otherUser, size: 40),
      title: Text(
        otherUser.displayName?.isNotEmpty == true
            ? otherUser.displayName!
            : otherUser.username,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: thread.isUnread ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _ThreadMetaColumn(thread: thread, ref: ref),
      onTap: () => context.push('/chat/user/${otherUser.id}', extra: otherUser),
    );
  }

  String _senderShortName(ChatMessage message) {
    final dn = message.fromUser.displayName;
    if (dn != null && dn.isNotEmpty) return dn;
    return message.fromUser.username;
  }

  String _previewText(ChatMessage message) {
    if (message.text != null && message.text!.isNotEmpty) return message.text!;
    if (message.file != null) {
      switch (message.file!.type) {
        case AttachmentType.image:
          return '[画像]';
        case AttachmentType.video:
          return '[動画]';
        case AttachmentType.audio:
          return '[音声]';
        case AttachmentType.gifv:
          return '[GIF]';
        case AttachmentType.unknown:
          return '[ファイル]';
      }
    }
    return '';
  }
}

class _ThreadMetaColumn extends StatelessWidget {
  final ChatThread thread;
  final WidgetRef ref;

  const _ThreadMetaColumn({required this.thread, required this.ref});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          _formatTime(ref, thread.lastMessage.createdAt),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (thread.isUnread)
          Container(
            margin: const EdgeInsets.only(top: 4),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
      ],
    );
  }

  // chat_thread_screen / post_tile / notification_tile と同じ表示モード
  // (display_settings の absoluteTimeProvider) に追従する (#560)。
  String _formatTime(WidgetRef ref, DateTime createdAt) {
    if (ref.watch(absoluteTimeProvider)) {
      final local = createdAt.toLocal();
      return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
          '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    final diff = DateTime.now().toUtc().difference(createdAt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 30) return '${diff.inDays}日前';
    final months = diff.inDays ~/ 30;
    if (months < 12) return '$monthsヶ月前';
    return '${diff.inDays ~/ 365}年前';
  }
}
