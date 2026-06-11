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

class ChatThreadScreen extends ConsumerStatefulWidget {
  final User otherUser;

  const ChatThreadScreen({super.key, required this.otherUser});

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  bool _sending = false;
  // 添付中のドライブファイル (#613)。未添付なら null。
  Attachment? _attachedFile;
  bool _uploading = false;

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
      ref.read(chatThreadProvider(widget.otherUser.id).notifier).loadMore();
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    final file = _attachedFile;
    // テキストも添付も無ければ送らない (#613)。
    if ((text.isEmpty && file == null) || _sending) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(chatThreadProvider(widget.otherUser.id).notifier)
          .send(text, fileId: file?.id);
      _textController.clear();
      if (mounted) setState(() => _attachedFile = null);
    } catch (e, st) {
      reportChatOpFailure(
        'send_message',
        e,
        st,
        account: ref.read(currentAccountProvider),
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
    setState(() => _uploading = true);
    try {
      final file = await showChatAttachmentPicker(context, ref);
      if (file != null && mounted) setState(() => _attachedFile = file);
    } catch (e, st) {
      reportChatOpFailure(
        'attach_file',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ファイルの添付に失敗しました (${summarizeOpError(e)})')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
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
          .read(chatThreadProvider(widget.otherUser.id).notifier)
          .deleteMessage(message.id);
    } catch (e, st) {
      reportChatOpFailure(
        'delete_message',
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
          .read(chatThreadProvider(widget.otherUser.id).notifier)
          .toggleReaction(messageId, reaction);
    } catch (e, st) {
      reportChatOpFailure(
        'react_message',
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
    final state = ref.watch(chatThreadProvider(widget.otherUser.id));
    final adapter = ref.watch(currentAdapterProvider);
    // readonly ロールでは送信不可。compose row 自体を隠す (#446)。
    final canSend =
        adapter is ChatSupport && (adapter as ChatSupport).canWriteChat;
    final displayName = widget.otherUser.displayName?.isNotEmpty == true
        ? widget.otherUser.displayName!
        : widget.otherUser.username;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            UserAvatar(user: widget.otherUser, size: 32),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                displayName,
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
                              '読み込みに失敗しました\n${summarizeOpError(error)}',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: () => ref.invalidate(
                                chatThreadProvider(widget.otherUser.id),
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
            // readonly ロールの注記。compose row 非表示の理由をユーザーに伝える。
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
    // ストリーミングが切れている / バックグラウンド復帰直後などで取りこぼしが
    // 起こり得るため、引っぱり更新で能動的に再取得できる経路を用意する。
    return RefreshIndicator(
      onRefresh: () =>
          ref.refresh(chatThreadProvider(widget.otherUser.id).future),
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
                return _MessageBubble(
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

class _MessageBubble extends ConsumerStatefulWidget {
  final ChatMessage message;
  final bool isMine;
  final String? myUserId;
  final VoidCallback? onLongPress;
  final void Function(String reaction)? onToggleReaction;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    this.myUserId,
    this.onLongPress,
    this.onToggleReaction,
  });

  @override
  ConsumerState<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<_MessageBubble> {
  ContentRenderer? _contentRenderer;

  @override
  void dispose() {
    _contentRenderer?.dispose();
    super.dispose();
  }

  /// メッセージ本文を post_tile と同じ ContentRenderer (MFM) でレンダリング
  /// する (#449)。Misskey の chat は MFM のみで HTML は来ない。emojis は
  /// メッセージ自体の `emojis` と送信者の `emojis` をマージ。
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

    final children = <Widget>[];
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
                          // post_tile / notification_tile と同じ表示モード
                          // (display_settings の absoluteTimeProvider) に追従
                          // する (#560)。日付が分からないと「いつのメッセージ
                          // か」が読み取れないため、時刻のみの表示は廃止して
                          // いる。
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
              // 相手のバブルはアバター幅 (32 + gap 8) ぶん字下げして reaction を
              // バブル左端に揃える。
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

