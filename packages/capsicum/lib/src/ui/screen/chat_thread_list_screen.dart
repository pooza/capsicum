import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/chat_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../util/oauth_scope_error.dart';
import '../util/op_error.dart';
import '../util/relative_time.dart';
import '../widget/oauth_scope_error_view.dart';
import '../widget/retry_error_view.dart';
import '../widget/user_avatar.dart';

class ChatThreadListScreen extends ConsumerStatefulWidget {
  const ChatThreadListScreen({super.key});

  @override
  ConsumerState<ChatThreadListScreen> createState() =>
      _ChatThreadListScreenState();
}

class _ChatThreadListScreenState extends ConsumerState<ChatThreadListScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // OS 復帰時に thread list を再取得して最新化する (#637)。
  // chatRoomMessageStreamProvider は入室画面でしか購読されないため、閉じている
  // ルームに来た新着では thread list が並び替わらない。全所属ルームを常時購読
  // すると WebSocket 接続数がルーム数だけ増えサーバー / バッテリーに響くため、
  // 完全 realtime は諦め「復帰時に getChatHistory(room) を再 fetch する」妥協
  // ラインを採る。一覧を前面で開いたまま新着が来るケースは既存の
  // pull-to-refresh で補う。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ref.exists(chatThreadListProvider)) {
      ref.invalidate(chatThreadListProvider);
    }
  }

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
              subtitle: const Text('複数人でメッセージをやり取りする'),
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
  Widget build(BuildContext context) {
    final threads = ref.watch(chatThreadListProvider);
    final invitations = ref.watch(chatInvitationInboxProvider);
    final invitationCount = invitations.maybeWhen(
      data: (list) => list.length,
      orElse: () => 0,
    );

    // chat (DM) streaming の再接続上限到達を SnackBar 表示 (#623)。
    // timeline 側 (#602) と同型。flag は autoDispose で再購読時にクリアされる。
    ref.listen(chatStreamReconnectExhaustedProvider, (prev, next) {
      if (next && prev != true) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('メッセージのライブ更新が停止しました。下に引いて再接続してください'),
              duration: Duration(seconds: 5),
            ),
          );
        }
      }
    });

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
        data: (list) => RefreshIndicator(
          onRefresh: () => ref.refresh(chatThreadListProvider.future),
          // empty でも pull-to-refresh を効かせるため LayoutBuilder +
          // AlwaysScrollableScrollPhysics で常にスクロール可能にする。
          child: list.isEmpty
              ? LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: const Center(child: Text('メッセージはありません')),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _ChatThreadTile(thread: list[index]),
                ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => isOAuthScopeError(error)
            ? const OAuthScopeErrorView()
            : RetryErrorView(
                message: '読み込みに失敗しました\n${summarizeOpError(error)}',
                selectable: true,
                isRetrying: threads.isLoading,
                onRetry: () => ref.invalidate(chatThreadListProvider),
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
        // chat_thread_screen / post_tile / notification_tile と同じ表示モード
        // (display_settings の absoluteTimeProvider) に追従する (#560)。
        TimestampText(
          thread.lastMessage.createdAt,
          absolute: ref.watch(absoluteTimeProvider),
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
}
