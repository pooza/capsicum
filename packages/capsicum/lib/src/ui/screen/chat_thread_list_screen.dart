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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threads = ref.watch(chatThreadListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('メッセージ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/chat/new'),
        tooltip: '新しいメッセージ',
        child: const Icon(Icons.edit),
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
    // Phase A 時点では room 含む history はまだ取得経路がない (#438 Phase D で
    // ルーム dispatch を追加)。ここでは DM 前提で otherUser を decompose する。
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
      trailing: Column(
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
      ),
      onTap: () => context.push(
        '/chat/user/${otherUser.id}',
        extra: otherUser,
      ),
    );
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
