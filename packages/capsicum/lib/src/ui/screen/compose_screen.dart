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
import '../widget/emoji_text.dart';

class _MediaEntry {
  final XFile file;
  String description = '';
  bool sensitive = false;

  _MediaEntry(this.file);
}

class ComposeScreen extends ConsumerStatefulWidget {
  final Post? redraft;
  final Post? replyTo;

  const ComposeScreen({super.key, this.redraft, this.replyTo});

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _controller = TextEditingController();
  final _cwController = TextEditingController();
  final _imagePicker = ImagePicker();
  final List<_MediaEntry> _attachments = [];
  PostScope _scope = PostScope.public;
  bool _cwEnabled = false;
  bool _sensitiveEnabled = false;
  bool _sending = false;

  static const _mastodonScopeLabels = {
    PostScope.public: '公開',
    PostScope.unlisted: 'ひかえめな公開',
    PostScope.followersOnly: 'フォロワー',
    PostScope.direct: '非公開の返信',
  };

  static const _misskeyScopeLabels = {
    PostScope.public: 'パブリック',
    PostScope.unlisted: 'ホーム',
    PostScope.followersOnly: 'フォロワー',
    PostScope.direct: 'ダイレクト',
  };

  static const _scopeIcons = {
    PostScope.public: Icons.public,
    PostScope.unlisted: Icons.lock_open,
    PostScope.followersOnly: Icons.lock,
    PostScope.direct: Icons.mail,
  };

  List<DropdownMenuItem<PostScope>> _scopeItems(WidgetRef ref) {
    final adapter = ref.read(currentAdapterProvider);
    final isMisskey = adapter is ReactionSupport;
    final labels = isMisskey ? _misskeyScopeLabels : _mastodonScopeLabels;

    return PostScope.values.map((scope) {
      return DropdownMenuItem(
        value: scope,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_scopeIcons[scope], size: 18),
            const SizedBox(width: 4),
            Text(labels[scope]!),
          ],
        ),
      );
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    final redraft = widget.redraft;
    final replyTo = widget.replyTo;
    if (redraft != null) {
      _controller.text = _extractPlainText(redraft.content ?? '');
      _scope = redraft.scope;
    } else if (replyTo != null) {
      _scope = replyTo.scope;
      _initReplyMentions(replyTo);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _cwController.dispose();
    super.dispose();
  }

  void _initReplyMentions(Post replyTo) {
    final currentUser = ref.read(currentAccountProvider)?.user;
    final mentions = <String>{};

    // Add the author of the post being replied to.
    final authorAcct = _buildAcct(replyTo.author);
    if (currentUser == null || replyTo.author.id != currentUser.id) {
      mentions.add(authorAcct);
    }

    if (mentions.isNotEmpty) {
      final prefix = mentions.map((m) => '@$m').join(' ');
      _controller.text = '$prefix ';
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  String _buildAcct(User user) {
    if (user.host != null && user.host!.isNotEmpty) {
      return '${user.username}@${user.host}';
    }
    return user.username;
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
      setState(() {
        _attachments.addAll(files.map((f) => _MediaEntry(f)));
      });
    }
  }

  void _removeAttachment(int index) {
    setState(() => _attachments.removeAt(index));
  }

  static const _videoExtensions = {
    'mov',
    'mp4',
    'avi',
    'mkv',
    'webm',
    'm4v',
    '3gp',
  };

  bool _isVideo(String? mimeType, [String? path]) {
    if (mimeType != null && mimeType.startsWith('video/')) return true;
    if (path != null) {
      final ext = path.toLowerCase().split('.').last;
      return _videoExtensions.contains(ext);
    }
    return false;
  }

  Future<void> _editDescription(int index) async {
    final entry = _attachments[index];
    final descController = TextEditingController(text: entry.description);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('メディアの説明'),
        content: TextField(
          controller: descController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '画像の説明を入力（ALT テキスト）',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, descController.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result != null) {
      setState(() => entry.description = result);
    }
  }

  Future<void> _openEpisodeBrowser() async {
    final result = await context.push<String>('/episodes');
    if (result != null && mounted) {
      _controller.text = result;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  Future<void> _showTagsetSheet() async {
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    if (mulukhiya == null) return;

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return _TagsetSheet(
          mulukhiya: mulukhiya,
          annictEnabled: mulukhiya.annictEnabled,
          onSelect: (program) {
            Navigator.pop(sheetContext);
            _insertTagsetYaml(program);
          },
          onClear: () {
            Navigator.pop(sheetContext);
            _insertTagsetYaml(null);
          },
          onEpisodeBrowser: () {
            Navigator.pop(sheetContext);
            _openEpisodeBrowser();
          },
          onReload: () async {
            try {
              await mulukhiya.updateProgram();
              if (sheetContext.mounted) {
                Navigator.pop(sheetContext);
              }
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('番組表を更新しました')));
              }
            } catch (e) {
              if (sheetContext.mounted) {
                Navigator.pop(sheetContext);
              }
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('更新に失敗しました')));
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

  bool get _effectiveSensitive => _cwEnabled || _sensitiveEnabled;

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    setState(() => _sending = true);
    try {
      // Upload attachments in parallel.
      final mediaIds = await Future.wait(
        _attachments.map((entry) async {
          final draft = AttachmentDraft(
            filePath: entry.file.path,
            description: entry.description.isNotEmpty
                ? entry.description
                : null,
            mimeType: entry.file.mimeType,
            sensitive: _effectiveSensitive || entry.sensitive,
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
          inReplyToId: widget.replyTo?.id,
          mediaIds: mediaIds,
          spoilerText: spoilerText?.isNotEmpty == true ? spoilerText : null,
          sensitive: _effectiveSensitive,
        ),
      );
      if (mounted) {
        ref.invalidate(timelineProvider);
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${ref.read(postLabelProvider)}に失敗しました')),
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
        title: Text(
          widget.replyTo != null ? 'リプライ' : ref.watch(postLabelProvider),
        ),
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
            if (widget.replyTo != null) _ReplyPreview(post: widget.replyTo!),
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
                    final entry = _attachments[index];
                    final isVideo = _isVideo(
                      entry.file.mimeType,
                      entry.file.path,
                    );
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _sending ? null : () => _editDescription(index),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: isVideo
                                ? Container(
                                    width: 100,
                                    height: 100,
                                    color: Colors.black87,
                                    child: const Center(
                                      child: Icon(
                                        Icons.videocam,
                                        color: Colors.white,
                                        size: 36,
                                      ),
                                    ),
                                  )
                                : Image.file(
                                    File(entry.file.path),
                                    width: 100,
                                    height: 100,
                                    fit: BoxFit.cover,
                                  ),
                          ),
                          // ALT badge
                          if (entry.description.isNotEmpty)
                            Positioned(
                              bottom: 4,
                              left: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'ALT',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          // Remove button
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
                      ),
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
                if (_attachments.isNotEmpty)
                  IconButton(
                    onPressed: _sending
                        ? null
                        : () => setState(
                            () => _sensitiveEnabled = !_sensitiveEnabled,
                          ),
                    icon: Icon(
                      _effectiveSensitive
                          ? Icons.visibility_off
                          : Icons.visibility,
                      color: _effectiveSensitive
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    tooltip: '閲覧注意メディア',
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
                  items: _scopeItems(ref),
                ),
                const Spacer(),
                if (maxLength != null)
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (context, value, _) {
                      final len = value.text.length;
                      return Text(
                        '$len / $maxLength',
                        style: TextStyle(
                          color: len > maxLength
                              ? Theme.of(context).colorScheme.error
                              : len > maxLength * 0.8
                              ? Colors.orange
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  final Post post;

  const _ReplyPreview({required this.post});

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

  @override
  Widget build(BuildContext context) {
    final displayName = post.author.displayName ?? post.author.username;
    final preview = _extractPlainText(post.content ?? '');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.reply,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                EmojiText(
                  displayName,
                  emojis: post.author.emojis,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (preview.isNotEmpty)
                  Text(
                    preview,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TagsetSheet extends StatefulWidget {
  final MulukhiyaService mulukhiya;
  final bool annictEnabled;
  final void Function(MulukhiyaProgram program) onSelect;
  final VoidCallback onClear;
  final VoidCallback? onEpisodeBrowser;
  final VoidCallback onReload;

  const _TagsetSheet({
    required this.mulukhiya,
    this.annictEnabled = false,
    required this.onSelect,
    required this.onClear,
    this.onEpisodeBrowser,
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
                  if (widget.annictEnabled && widget.onEpisodeBrowser != null)
                    ListTile(
                      leading: const Icon(Icons.video_library),
                      title: const Text('エピソードブラウザ'),
                      onTap: widget.onEpisodeBrowser,
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
