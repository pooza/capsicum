import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/timeline_provider.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  final Post? redraft;

  const ComposeScreen({super.key, this.redraft});

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _controller = TextEditingController();
  final _cwController = TextEditingController();
  final _imagePicker = ImagePicker();
  final List<XFile> _attachments = [];
  PostScope _scope = PostScope.public;
  bool _cwEnabled = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final redraft = widget.redraft;
    if (redraft != null) {
      _controller.text = _extractPlainText(redraft.content ?? '');
      _scope = redraft.scope;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _cwController.dispose();
    super.dispose();
  }

  String _extractPlainText(String content) {
    final isHtml = content.contains('<') && content.contains('>');
    if (!isHtml) return content;
    var text = content
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '');
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
    return text;
  }

  Future<void> _pickMedia() async {
    final files = await _imagePicker.pickMultipleMedia();
    if (files.isNotEmpty) {
      setState(() => _attachments.addAll(files));
    }
  }

  void _removeAttachment(int index) {
    setState(() => _attachments.removeAt(index));
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    setState(() => _sending = true);
    try {
      // Upload attachments in parallel.
      final mediaIds = await Future.wait(
        _attachments.map((file) async {
          final draft = AttachmentDraft(
            filePath: file.path,
            mimeType: file.mimeType,
            sensitive: _cwEnabled,
          );
          final attachment = await adapter.uploadAttachment(draft);
          return attachment.id;
        }),
      );

      final spoilerText = _cwEnabled ? _cwController.text.trim() : null;
      await adapter.postStatus(
        PostDraft(
          content: text.isNotEmpty ? text : null,
          scope: _scope,
          mediaIds: mediaIds,
          spoilerText: spoilerText?.isNotEmpty == true ? spoilerText : null,
          sensitive: _cwEnabled,
        ),
      );
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
            if (_cwEnabled)
              TextField(
                controller: _cwController,
                enabled: !_sending,
                decoration: const InputDecoration(
                  hintText: '閲覧注意の警告文',
                  border: UnderlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
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
            if (_attachments.isNotEmpty) ...[
              const Divider(),
              SizedBox(
                height: 100,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _attachments.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    return Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(_attachments[index].path),
                            width: 100,
                            height: 100,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: GestureDetector(
                            onTap: _sending
                                ? null
                                : () => _removeAttachment(index),
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(4),
                              child: const Icon(
                                Icons.close,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
            const Divider(),
            Row(
              children: [
                IconButton(
                  onPressed: _sending ? null : _pickMedia,
                  icon: const Icon(Icons.photo),
                  tooltip: 'メディアを添付',
                ),
                IconButton(
                  onPressed: _sending
                      ? null
                      : () => setState(() => _cwEnabled = !_cwEnabled),
                  icon: Icon(
                    Icons.warning_amber,
                    color: _cwEnabled
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  tooltip: '閲覧注意',
                ),
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
