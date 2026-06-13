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
import '../util/op_error.dart';
import '../util/relative_time.dart';
import '../widget/chat_compose_row.dart';
import '../widget/chat_reaction_bar.dart';
import '../widget/content_parser.dart';
import '../widget/oauth_scope_error_view.dart';
import '../widget/user_avatar.dart';
import 'chat_room_edit_screen.dart';

enum _RoomMenuAction { members, toggleMute, edit, leave, delete }

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
  // 添付中のドライブファイル (#613)。未添付なら null。
  Attachment? _attachedFile;
  bool _uploading = false;
  // initialRoom は immutable な widget.room を起点に、編集 / ミュート結果で
  // ローカル更新する mutable cache。AppBar タイトルや overflow メニューの
  // 既読は再 build で反映される。
  late ChatRoom _room = widget.room;

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
    final file = _attachedFile;
    // テキストも添付も無ければ送らない (#613)。
    if ((text.isEmpty && file == null) || _sending) return;
    // ref.read は await をまたぐ前に退避する (#698 / #665 同型)。
    final account = ref.read(currentAccountProvider);
    setState(() => _sending = true);
    try {
      await ref
          .read(chatRoomTimelineProvider(widget.room.id).notifier)
          .send(text, fileId: file?.id);
      _textController.clear();
      if (mounted) setState(() => _attachedFile = null);
    } catch (e, st) {
      reportChatOpFailure(
        'send_room_message',
        e,
        st,
        account: account,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('送信に失敗しました (${summarizeOpError(e)})')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAttachment() async {
    // ref.read は await をまたぐ前に退避する (#698 / #665 同型)。
    final account = ref.read(currentAccountProvider);
    setState(() => _uploading = true);
    try {
      final file = await showChatAttachmentPicker(context, ref);
      if (file != null && mounted) setState(() => _attachedFile = file);
    } catch (e, st) {
      reportChatOpFailure(
        'attach_room_file',
        e,
        st,
        account: account,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ファイルの添付に失敗しました (${summarizeOpError(e)})')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _toggleMute() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return;
    final target = !_room.isMuted;
    try {
      await (adapter as ChatSupport).setRoomMute(
        roomId: _room.id,
        mute: target,
      );
      // ChatRoom には copyWith が無いので再構築。Phase E.1 範囲では他経路で
      // ミュート状態の参照は無いが、AppBar アイコン切替のため反映する。
      if (!mounted) return;
      setState(
        () => _room = ChatRoom(
          id: _room.id,
          createdAt: _room.createdAt,
          name: _room.name,
          description: _room.description,
          ownerId: _room.ownerId,
          owner: _room.owner,
          isMuted: target,
          invitationExists: _room.invitationExists,
        ),
      );
      ref.invalidate(chatThreadListProvider);
    } catch (e, st) {
      reportChatOpFailure(
        'toggle_room_mute',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${target ? "ミュート" : "ミュート解除"}に失敗しました (${summarizeOpError(e)})',
          ),
        ),
      );
    }
  }

  Future<void> _edit() async {
    final updated = await Navigator.of(context).push<ChatRoom?>(
      MaterialPageRoute(builder: (_) => ChatRoomEditScreen(initialRoom: _room)),
    );
    if (updated != null && mounted) {
      setState(() => _room = updated);
    }
  }

  Future<void> _confirmLeave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ルームを退出しますか？'),
        content: Text('${_room.name} から退出します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return;
    try {
      await (adapter as ChatSupport).leaveRoom(_room.id);
      ref.invalidate(joiningChatRoomsProvider);
      ref.invalidate(chatThreadListProvider);
      if (!mounted) return;
      context.go('/chat');
    } catch (e, st) {
      reportChatOpFailure(
        'leave_room',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('退出に失敗しました (${summarizeOpError(e)})')),
      );
    }
  }

  Future<void> _confirmDeleteRoom() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ルームを削除しますか？'),
        content: Text('${_room.name} を削除します。\nこの操作は取り消せず、全メンバーから見えなくなります。'),
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
    if (ok != true || !mounted) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return;
    try {
      await (adapter as ChatSupport).deleteRoom(_room.id);
      ref.invalidate(joiningChatRoomsProvider);
      ref.invalidate(chatThreadListProvider);
      if (!mounted) return;
      context.go('/chat');
    } catch (e, st) {
      reportChatOpFailure(
        'delete_room',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('削除に失敗しました (${summarizeOpError(e)})')),
      );
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
      reportChatOpFailure(
        'delete_room_message',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('削除に失敗しました (${summarizeOpError(e)})')),
      );
    }
  }

  void _showActions(ChatMessage message, bool isMine) {
    showChatMessageActions(
      context: context,
      canDelete: isMine,
      // 自分のメッセージは Misskey 仕様で自己リアクション不可 (#612)。
      canReact: !isMine,
      onReact: () => showChatReactionPicker(
        context: context,
        ref: ref,
        onPicked: (reaction) => _toggleReaction(message.id, reaction),
      ),
      onDelete: () => _confirmDelete(message),
    );
  }

  Future<void> _toggleReaction(String messageId, String reaction) async {
    try {
      await ref
          .read(chatRoomTimelineProvider(widget.room.id).notifier)
          .toggleReaction(messageId, reaction);
    } catch (e, st) {
      reportChatOpFailure(
        'react_room_message',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('リアクションに失敗しました (${summarizeOpError(e)})')),
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

    final myUserIdForOwnerCheck = ref.watch(currentAccountProvider)?.user.id;
    final isOwner =
        myUserIdForOwnerCheck != null && _room.ownerId == myUserIdForOwnerCheck;

    // chatRoom streaming の再接続上限到達を SnackBar 表示 (#623)。
    // DM 側 ([chatStreamReconnectExhaustedProvider]) と同型。
    ref.listen(chatRoomStreamReconnectExhaustedProvider(widget.room.id), (
      prev,
      next,
    ) {
      if (next && prev != true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ルームのライブ更新が停止しました。下に引いて再接続してください'),
              duration: Duration(seconds: 5),
            ),
          );
        }
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.groups, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _room.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_room.isMuted)
            IconButton(
              icon: const Icon(Icons.notifications_off),
              tooltip: 'ミュート中',
              onPressed: _toggleMute,
            ),
          PopupMenuButton<_RoomMenuAction>(
            onSelected: (action) {
              switch (action) {
                case _RoomMenuAction.members:
                  context.push('/chat/room/${_room.id}/members', extra: _room);
                case _RoomMenuAction.toggleMute:
                  _toggleMute();
                case _RoomMenuAction.edit:
                  _edit();
                case _RoomMenuAction.leave:
                  _confirmLeave();
                case _RoomMenuAction.delete:
                  _confirmDeleteRoom();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _RoomMenuAction.members,
                child: ListTile(
                  leading: Icon(Icons.people),
                  title: Text('メンバー'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _RoomMenuAction.toggleMute,
                child: ListTile(
                  leading: Icon(
                    _room.isMuted
                        ? Icons.notifications_active
                        : Icons.notifications_off,
                  ),
                  title: Text(_room.isMuted ? 'ミュート解除' : 'ミュート'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (isOwner)
                const PopupMenuItem(
                  value: _RoomMenuAction.edit,
                  child: ListTile(
                    leading: Icon(Icons.edit),
                    title: Text('編集'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (!isOwner)
                const PopupMenuItem(
                  value: _RoomMenuAction.leave,
                  child: ListTile(
                    leading: Icon(Icons.logout),
                    title: Text('退出'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (isOwner)
                const PopupMenuItem(
                  value: _RoomMenuAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_forever),
                    title: Text('ルームを削除'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
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
                              '読み込みに失敗しました\n${summarizeOpError(error)}',
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
            ChatComposeRow(
              controller: _textController,
              sending: _sending,
              uploading: _uploading,
              attachedFile: _attachedFile,
              onSend: _send,
              onAttach: _pickAttachment,
              onRemoveAttachment: () => setState(() => _attachedFile = null),
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
    // DM タイムラインと同じく、ストリーミング取りこぼし対策として引っぱり
    // 更新を入れておく。
    return RefreshIndicator(
      onRefresh: () =>
          ref.refresh(chatRoomTimelineProvider(widget.room.id).future),
      child: data.messages.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 160),
                Center(child: Text('メッセージはありません')),
              ],
            )
          : ListView.builder(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
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
                final isMine =
                    myUserId != null && message.fromUser.id == myUserId;
                return _RoomMessageBubble(
                  message: message,
                  isMine: isMine,
                  myUserId: myUserId,
                  onLongPress: () => _showActions(message, isMine),
                  onToggleReaction: (reaction) =>
                      _toggleReaction(message.id, reaction),
                );
              },
            ),
    );
  }
}

class _RoomMessageBubble extends ConsumerStatefulWidget {
  final ChatMessage message;
  final bool isMine;
  final String? myUserId;
  final VoidCallback? onLongPress;
  final void Function(String reaction)? onToggleReaction;

  const _RoomMessageBubble({
    required this.message,
    required this.isMine,
    this.myUserId,
    this.onLongPress,
    this.onToggleReaction,
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

    final localHost = ref.watch(currentAccountProvider)?.key.host;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: isMine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
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
                          formatTimestamp(
                            message.createdAt,
                            absolute: ref.watch(absoluteTimeProvider),
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
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
          if (message.reactions.isNotEmpty && widget.onToggleReaction != null)
            Padding(
              padding: EdgeInsets.only(top: 4, left: isMine ? 0 : 40),
              child: ChatReactionBar(
                message: message,
                myUserId: widget.myUserId,
                host: localHost,
                // 自分のメッセージのチップは表示のみ (自己リアクション不可)。
                interactive: !isMine,
                onToggle: widget.onToggleReaction!,
              ),
            ),
        ],
      ),
    );
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
