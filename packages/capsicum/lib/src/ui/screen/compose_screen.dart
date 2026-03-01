import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/timeline_provider.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key});

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _controller = TextEditingController();
  PostScope _scope = PostScope.public;
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    setState(() => _sending = true);
    try {
      await adapter.postStatus(PostDraft(content: text, scope: _scope));
      if (mounted) {
        ref.invalidate(timelineProvider);
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('投稿に失敗しました: $e')));
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(currentAdapterProvider);
    final maxLength = adapter?.capabilities.maxPostContentLength;

    return Scaffold(
      appBar: AppBar(
        title: const Text('投稿'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            onPressed: _sending ? null : _submit,
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                autofocus: true,
                enabled: !_sending,
                decoration: const InputDecoration(
                  hintText: '今なにしてる？',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const Divider(),
            Row(
              children: [
                DropdownButton<PostScope>(
                  value: _scope,
                  underline: const SizedBox.shrink(),
                  onChanged: _sending
                      ? null
                      : (value) {
                          if (value != null) setState(() => _scope = value);
                        },
                  items: const [
                    DropdownMenuItem(
                      value: PostScope.public,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.public, size: 18),
                          SizedBox(width: 4),
                          Text('公開'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: PostScope.unlisted,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock_open, size: 18),
                          SizedBox(width: 4),
                          Text('未収載'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: PostScope.followersOnly,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock, size: 18),
                          SizedBox(width: 4),
                          Text('フォロワー限定'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: PostScope.direct,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.mail, size: 18),
                          SizedBox(width: 4),
                          Text('ダイレクト'),
                        ],
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                if (maxLength != null)
                  Text(
                    '${_controller.text.length} / $maxLength',
                    style: TextStyle(
                      color: _controller.text.length > maxLength
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
