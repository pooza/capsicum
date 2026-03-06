import 'dart:io';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
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

  Future<void> _showTagsetSheet() async {
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    if (mulukhiya == null) return;

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return _TagsetSheet(
          mulukhiya: mulukhiya,
          onSelect: (program) {
            Navigator.pop(sheetContext);
            _insertTagsetYaml(program);
          },
          onClear: () {
            Navigator.pop(sheetContext);
            _insertTagsetYaml(null);
          },
          onReload: () async {
            try {
              await mulukhiya.updateProgram();
              if (sheetContext.mounted) {
                Navigator.pop(sheetContext);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('番組表を更新しました')));
              }
            } catch (e) {
              if (sheetContext.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('更新に失敗しました: $e')));
              }
            }
          },
        );
      },
    );
  }

  void _insertTagsetYaml(MulukhiyaProgram? program) {
    final String yaml;

    if (program == null) {
      yaml = 'command: user_config\ntagging:\n  user_tags: null';
    } else {
      final tags = <String>[];
      if (program.series != null) tags.add(program.series!);
      if (program.air) tags.add('エア番組');
      if (program.livecure) tags.add('実況');
      if (program.episode != null) {
        tags.add('第${program.episode}${program.episodeSuffix ?? '話'}');
      }
      if (program.subtitle != null) tags.add(program.subtitle!);
      tags.addAll(program.extraTags);

      final yamlTags = tags.map((t) => '    - $t').join('\n');
      final lines = ['command: user_config', 'tagging:', '  user_tags:'];
      lines.add(yamlTags);
      if (program.minutes != null) {
        lines.add('  minutes: ${program.minutes}');
      }
      yaml = lines.join('\n');
    }

    _controller.text = yaml;
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${ref.read(postLabelProvider)}に失敗しました: $e')),
        );
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxLength = ref.watch(maxPostLengthProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.watch(postLabelProvider)),
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
                if (ref.watch(currentMulukhiyaProvider) != null)
                  IconButton(
                    onPressed: _sending ? null : _showTagsetSheet,
                    icon: const Icon(Icons.live_tv),
                    tooltip: '実況',
                  ),
              ],
            ),
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
                          : _controller.text.length > maxLength * 0.8
                          ? Colors.orange
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

class _TagsetSheet extends StatefulWidget {
  final MulukhiyaService mulukhiya;
  final void Function(MulukhiyaProgram program) onSelect;
  final VoidCallback onClear;
  final VoidCallback onReload;

  const _TagsetSheet({
    required this.mulukhiya,
    required this.onSelect,
    required this.onClear,
    required this.onReload,
  });

  @override
  State<_TagsetSheet> createState() => _TagsetSheetState();
}

class _TagsetSheetState extends State<_TagsetSheet> {
  Map<String, MulukhiyaProgram>? _programs;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPrograms();
  }

  Future<void> _loadPrograms() async {
    try {
      final programs = await widget.mulukhiya.getProgram();
      if (mounted) {
        setState(() {
          _programs = programs;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  String _programLabel(MulukhiyaProgram p) {
    final parts = <String>[];
    if (p.series != null) parts.add(p.series!);
    if (p.episode != null) {
      parts.add('第${p.episode}${p.episodeSuffix ?? '話'}');
    }
    if (p.subtitle != null) parts.add(p.subtitle!);
    return parts.isNotEmpty ? parts.join(' ') : p.name;
  }

  String _programSublabel(MulukhiyaProgram p) {
    final flags = <String>[];
    if (p.air) flags.add('エア番組');
    if (p.livecure) flags.add('実況');
    if (p.minutes != null) flags.add('${p.minutes}分');
    if (p.extraTags.isNotEmpty) flags.addAll(p.extraTags);
    return flags.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '実況タグセット',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('読み込みに失敗しました: $_error'),
            )
          else ...[
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(Icons.clear),
                    title: const Text('タグなし'),
                    subtitle: const Text('タグセットを削除し、実況を終了する'),
                    onTap: widget.onClear,
                  ),
                  if (_programs != null)
                    for (final entry in _programs!.entries)
                      ListTile(
                        leading: const Icon(Icons.live_tv),
                        title: Text(_programLabel(entry.value)),
                        subtitle: Text(_programSublabel(entry.value)),
                        onTap: () => widget.onSelect(entry.value),
                      ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('番組表を更新'),
                    subtitle: const Text('モロヘイヤから番組表をダウンロードし直す'),
                    onTap: widget.onReload,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
