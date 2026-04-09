import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/timeline_provider.dart';

class SimplePostBar extends ConsumerStatefulWidget {
  /// Channel ID to post into (Misskey channels).
  final String? channelId;

  /// Channel name for display in compose screen.
  final String? channelName;

  /// Hashtag to prepend to the post content.
  final String? hashtag;

  /// Called after a successful post (for refreshing the caller's timeline).
  final VoidCallback? onPosted;

  const SimplePostBar({
    super.key,
    this.channelId,
    this.channelName,
    this.hashtag,
    this.onPosted,
  });

  @override
  ConsumerState<SimplePostBar> createState() => _SimplePostBarState();
}

class _SimplePostBarState extends ConsumerState<SimplePostBar> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    if (await ref.read(confirmBeforePostProvider.notifier).readPersisted()) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('確認'),
          content: const Text('投稿しますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('投稿'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    final content = widget.hashtag != null
        ? '$text\n\n#${widget.hashtag}'
        : text;

    setState(() => _sending = true);
    try {
      await adapter.postStatus(
        PostDraft(content: content, channelId: widget.channelId),
      );
      if (mounted) {
        _controller.clear();
        ref.invalidate(timelineProvider);
        widget.onPosted?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${ref.read(postLabelProvider)}に失敗しました')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _openCompose() {
    final extra = <String, dynamic>{};
    final text = _controller.text;
    if (text.isNotEmpty) {
      extra['initialText'] = text;
    }
    if (widget.channelId != null) {
      extra['channelId'] = widget.channelId;
      extra['channelName'] = widget.channelName;
    }
    context.push('/compose', extra: extra.isNotEmpty ? extra : null);
  }

  @override
  Widget build(BuildContext context) {
    final postLabel = ref.watch(postLabelProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              enabled: !_sending,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: '$postLabel...',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 20),
            tooltip: '詳細な$postLabel画面',
            onPressed: _sending ? null : _openCompose,
          ),
          IconButton(
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            tooltip: postLabel,
            onPressed: _sending ? null : _submit,
          ),
        ],
      ),
    );
  }
}
