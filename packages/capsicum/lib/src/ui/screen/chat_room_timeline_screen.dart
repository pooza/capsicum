import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/chat_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../url_helper.dart';
import '../../util/oauth_scope_error.dart';
import '../util/chat_error.dart';
import '../widget/content_parser.dart';
import '../widget/oauth_scope_error_view.dart';
import '../widget/user_avatar.dart';

/// Misskey chat ルーム (グループチャット) のタイムライン画面 (#438)。DM 用
/// [ChatThreadScreen] と UI 構成は揃えるが、provider は
/// [chatRoomTimelineProvider]、送信は sendRoomMessage 経由。
class ChatRoomTimelineScreen extends ConsumerStatefulWidget {
  final ChatRoom room;

  const ChatRoomTimelineScreen({super.key, required this.room});

  @override
  ConsumerState<ChatRoomTimelineScreen> createState() =>
      _ChatRoomTimelineScreenState();
}

class _ChatRoomTimelineScreenState
    extends ConsumerState<ChatRoomTimelineScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 600) {
      ref.read(chatRoomTimelineProvider(widget.room.id).notifier).loadMore();
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(chatRoomTimelineProvider(widget.room.id).notifier)
          .send(text);
      _textController.clear();
    } catch (e, st) {
      reportChatOpFailure('send_room_message', e, st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('送信に失敗しました (${summarizeChatError(e)})')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _confirmDelete(ChatMessage message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('メッセージを削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    try {
      await ref
          .read(chatRoomTimelineProvider(widget.room.id).notifier)
          .deleteMessage(message.id);
    } catch (e, st) {
      reportChatOpFailure('delete_room_message', e, st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('削除に失敗しました (${summarizeChatError(e)})')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUserId = ref.watch(currentAccountProvider)?.user.id;
    final state = ref.watch(chatRoomTimelineProvider(widget.room.id));
    final adapter = ref.watch(currentAdapterProvider);
    final canSend =
        adapter is ChatSupport && (adapter as ChatSupport).canWriteChat;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              Icons.groups,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.room.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          Expanded(
            child: state.when(
              data: (data) => _buildMessageList(context, data, myUserId),
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
                              onPressed: () => ref.invalidate(
                                chatRoomTimelineProvider(widget.room.id),
                              ),
                              child: const Text('再試行'),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          if (canSend)
            _ComposeRow(
              controller: _textController,
              sending: _sending,
              onSend: _send,
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
              alignment: Alignment.center,
              child: Text(
                'このアカウントではメッセージを送信できません',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageList(
    BuildContext context,
    ChatThreadState data,
    String? myUserId,
  ) {
    if (data.messages.isEmpty) {
      return const Center(child: Text('メッセージはありません'));
    }
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      itemCount: data.messages.length + (data.isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= data.messages.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final message = data.messages[index];
        final isMine = myUserId != null && message.fromUser.id == myUserId;
        return _RoomMessageBubble(
          message: message,
          isMine: isMine,
          onLongPress: isMine ? () => _confirmDelete(message) : null,
        );
      },
    );
  }
}

class _RoomMessageBubble extends ConsumerStatefulWidget {
  final ChatMessage message;
  final bool isMine;
  final VoidCallback? onLongPress;

  const _RoomMessageBubble({
    required this.message,
    required this.isMine,
    this.onLongPress,
  });

  @override
  ConsumerState<_RoomMessageBubble> createState() => _RoomMessageBubbleState();
}

class _RoomMessageBubbleState extends ConsumerState<_RoomMessageBubble> {
  ContentRenderer? _contentRenderer;

  @override
  void dispose() {
    _contentRenderer?.dispose();
    super.dispose();
  }

  TextSpan _renderContent(String content, TextStyle baseStyle) {
    _contentRenderer?.dispose();
    final message = widget.message;
    final allEmojis = {...message.fromUser.emojis, ...message.emojis};
    final host = message.fromUser.host;
    _contentRenderer = ContentRenderer(
      baseStyle: baseStyle,
      resolveEmoji: (shortcode) {
        final url = allEmojis[shortcode];
        if (url != null) return url;
        if (host != null) return 'https://$host/emoji/$shortcode.webp';
        return null;
      },
      onLinkTap: (url) {
        final uri = Uri.tryParse(url);
        if (uri != null) launchUrlSafely(uri);
      },
      onLinkLongPress: (url) {
        Clipboard.setData(ClipboardData(text: url));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('URL をコピーしました'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      onHashtagTap: (tag) => context.push('/hashtag/$tag'),
      emojiSize: ref.watch(emojiSizeProvider),
      applyNyaize: message.fromUser.isCat,
    );
    return _contentRenderer!.renderMfm(content);
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isMine = widget.isMine;
    final onLongPress = widget.onLongPress;
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = isMine
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final textColor = isMine
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    // DM と違い、ルームでは送信者がメッセージごとに変わる。バブル上に
    // 送信者名 (自分以外) を出して誰の発言か分かるようにする。
    final senderName = message.fromUser.displayName?.isNotEmpty == true
        ? message.fromUser.displayName!
        : message.fromUser.username;

    final children = <Widget>[];
    if (!isMine) {
      children.add(
        Text(
          senderName,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: textColor.withValues(alpha: 0.8),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      children.add(const SizedBox(height: 4));
    }
    if (message.file != null) {
      children.add(_FilePreview(file: message.file!));
      if (message.text != null && message.text!.isNotEmpty) {
        children.add(const SizedBox(height: 6));
      }
    }
    if (message.text != null && message.text!.isNotEmpty) {
      final baseStyle = TextStyle(color: textColor);
      children.add(
        Text.rich(_renderContent(message.text!, baseStyle), style: baseStyle),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) ...[
            UserAvatar(user: message.fromUser, size: 32),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: onLongPress,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...children,
                    const SizedBox(height: 4),
                    Text(
                      _formatTime(message.createdAt),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: textColor.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    if (ref.watch(absoluteTimeProvider)) {
      final local = t.toLocal();
      return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
          '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    final diff = DateTime.now().toUtc().difference(t);
    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 30) return '${diff.inDays}日前';
    final months = diff.inDays ~/ 30;
    if (months < 12) return '$monthsヶ月前';
    return '${diff.inDays ~/ 365}年前';
  }
}

class _FilePreview extends StatelessWidget {
  final Attachment file;

  const _FilePreview({required this.file});

  @override
  Widget build(BuildContext context) {
    if (file.type == AttachmentType.image && file.url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          file.previewUrl?.isNotEmpty == true ? file.previewUrl! : file.url,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.broken_image_outlined, size: 32),
        ),
      );
    }
    final icon = switch (file.type) {
      AttachmentType.video => Icons.movie_outlined,
      AttachmentType.audio => Icons.audiotrack,
      AttachmentType.gifv => Icons.gif,
      _ => Icons.attach_file,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            file.name?.isNotEmpty == true ? file.name! : '[ファイル]',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _ComposeRow extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  const _ComposeRow({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                enabled: !sending,
                decoration: const InputDecoration(
                  hintText: 'メッセージを入力',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              icon: sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              onPressed: sending ? null : onSend,
            ),
          ],
        ),
      ),
    );
  }
}
