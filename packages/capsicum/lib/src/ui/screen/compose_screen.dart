import 'dart:io';

import 'dart:async';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/timeline_provider.dart';
import '../widget/emoji_picker.dart';
import '../widget/emoji_text.dart';
import 'drive_picker_screen.dart';

class _MediaEntry {
  final XFile? file;
  final Attachment? driveFile;
  String description = '';
  bool sensitive = false;

  _MediaEntry.local(XFile this.file) : driveFile = null;

  _MediaEntry.drive(Attachment this.driveFile)
    : file = null,
      description = driveFile.description ?? '',
      sensitive = false;

  bool get isDrive => driveFile != null;
}

class ComposeScreen extends ConsumerStatefulWidget {
  final Post? redraft;
  final Post? replyTo;
  final Post? quoteTo;
  final String? channelId;
  final String? channelName;

  const ComposeScreen({
    super.key,
    this.redraft,
    this.replyTo,
    this.quoteTo,
    this.channelId,
    this.channelName,
  });

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
  bool _localOnly = false;
  DateTime? _scheduledAt;
  String? _language;
  List<User> _mentionSuggestions = [];
  List<String> _hashtagSuggestions = [];
  Timer? _mentionDebounce;

  // Poll state
  bool _pollEnabled = false;
  final List<TextEditingController> _pollControllers = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _pollMultiple = false;
  int _pollExpiresIn = 86400; // 1 day in seconds

  static const _languageOptions = {
    'ja': '日本語',
    'en': 'English',
    'zh': '中文',
    'ko': '한국어',
    'fr': 'Français',
    'de': 'Deutsch',
    'es': 'Español',
    'pt': 'Português',
    'ru': 'Русский',
  };

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
    PostScope.direct: '指名',
  };

  static const _mastodonScopeIcons = {
    PostScope.public: Icons.public,
    PostScope.unlisted: Icons.nightlight_outlined,
    PostScope.followersOnly: Icons.lock_outline,
    PostScope.direct: Icons.alternate_email,
  };

  static const _misskeyScopeIcons = {
    PostScope.public: Icons.public,
    PostScope.unlisted: Icons.home_outlined,
    PostScope.followersOnly: Icons.lock_outline,
    PostScope.direct: Icons.mail_outline,
  };

  List<DropdownMenuItem<PostScope>> _scopeItems(WidgetRef ref) {
    final adapter = ref.read(currentAdapterProvider);
    final isMisskey = adapter is ReactionSupport;
    final labels = isMisskey ? _misskeyScopeLabels : _mastodonScopeLabels;
    final icons = isMisskey ? _misskeyScopeIcons : _mastodonScopeIcons;

    return PostScope.values.map((scope) {
      return DropdownMenuItem(
        value: scope,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icons[scope], size: 18),
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
    } else if (widget.quoteTo != null) {
      _scope = widget.quoteTo!.scope;
    }
    _controller.addListener(_onTextChanged);
    // Mastodon のみ: デフォルト言語をロケールから設定
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final adapter = ref.read(currentAdapterProvider);
      if (adapter is MastodonAdapter) {
        setState(
          () => _language = Localizations.localeOf(context).languageCode,
        );
      }
    });
  }

  /// Walk backwards from cursor to find [trigger] (`@` or `#`).
  /// Returns the query string after the trigger, or null.
  String? _currentTriggerQuery(String trigger) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) return null;
    var start = cursor - 1;
    while (start >= 0) {
      final ch = text[start];
      if (ch == trigger) {
        if (start == 0 || text[start - 1] == ' ' || text[start - 1] == '\n') {
          final query = text.substring(start + 1, cursor);
          return query.isNotEmpty ? query : null;
        }
        return null;
      }
      if (ch == ' ' || ch == '\n') return null;
      start--;
    }
    return null;
  }

  void _onTextChanged() {
    _mentionDebounce?.cancel();

    // Check mention trigger first, then hashtag.
    final mentionQuery = _currentTriggerQuery('@');
    final hashtagQuery = mentionQuery == null
        ? _currentTriggerQuery('#')
        : null;

    if (mentionQuery == null && _mentionSuggestions.isNotEmpty) {
      setState(() => _mentionSuggestions = []);
    }
    if (hashtagQuery == null && _hashtagSuggestions.isNotEmpty) {
      setState(() => _hashtagSuggestions = []);
    }

    if (mentionQuery != null) {
      _mentionDebounce = Timer(const Duration(milliseconds: 300), () {
        _fetchMentionSuggestions(mentionQuery);
      });
    } else if (hashtagQuery != null) {
      _mentionDebounce = Timer(const Duration(milliseconds: 300), () {
        _fetchHashtagSuggestions(hashtagQuery);
      });
    }
  }

  Future<void> _fetchMentionSuggestions(String query) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! SearchSupport) return;
    try {
      final users = await (adapter as SearchSupport).searchUsers(
        query,
        limit: 5,
      );
      if (mounted) setState(() => _mentionSuggestions = users);
    } catch (_) {
      // Silently ignore search failures.
    }
  }

  Future<void> _fetchHashtagSuggestions(String query) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! SearchSupport) return;
    try {
      final tags = await (adapter as SearchSupport).searchHashtags(
        query,
        limit: 5,
      );
      if (mounted) setState(() => _hashtagSuggestions = tags);
    } catch (_) {
      // Silently ignore search failures.
    }
  }

  void _insertMention(User user) {
    final acct = _buildAcct(user);
    _insertTriggerCompletion('@', '@$acct ');
    setState(() => _mentionSuggestions = []);
  }

  void _insertHashtag(String tag) {
    _insertTriggerCompletion('#', '#$tag ');
    setState(() => _hashtagSuggestions = []);
  }

  void _insertTriggerCompletion(String trigger, String replacement) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    var start = cursor - 1;
    while (start >= 0 && text[start] != trigger) {
      start--;
    }
    final newText = text.replaceRange(start, cursor, replacement);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
  }

  @override
  void dispose() {
    _mentionDebounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _cwController.dispose();
    for (final c in _pollControllers) {
      c.dispose();
    }
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

  void _insertEmoji(String emoji) {
    final text = _controller.text;
    final sel = _controller.selection;
    final start = sel.baseOffset < 0 ? text.length : sel.baseOffset;
    final end = sel.extentOffset < 0 ? text.length : sel.extentOffset;
    final newText = text.replaceRange(start, end, emoji);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  void _showEmojiPicker() {
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
    if (adapter == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.5,
        child: EmojiPicker(
          adapter: adapter as BackendAdapter,
          host: account!.key.host,
          onSelected: (emoji) {
            Navigator.pop(context);
            _insertEmoji(emoji);
          },
        ),
      ),
    );
  }

  Future<void> _pickMedia() async {
    final files = await _imagePicker.pickMultipleMedia();
    if (files.isNotEmpty) {
      setState(() {
        _attachments.addAll(files.map((f) => _MediaEntry.local(f)));
      });
    }
  }

  Future<void> _pickDriveFiles() async {
    final selected = await Navigator.of(context).push<List<Attachment>>(
      MaterialPageRoute(builder: (_) => const DrivePickerScreen()),
    );
    if (selected != null && selected.isNotEmpty) {
      setState(() {
        _attachments.addAll(selected.map((f) => _MediaEntry.drive(f)));
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

  Widget _buildThumbnail(_MediaEntry entry) {
    const size = 100.0;
    if (entry.isDrive) {
      final df = entry.driveFile!;
      final preview = df.previewUrl ?? df.url;
      final isImage =
          df.type == AttachmentType.image || df.type == AttachmentType.gifv;
      if (isImage && preview.isNotEmpty) {
        return Image.network(
          preview,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            width: size,
            height: size,
            color: Colors.black87,
            child: const Center(
              child: Icon(Icons.broken_image, color: Colors.white),
            ),
          ),
        );
      }
      return Container(
        width: size,
        height: size,
        color: Colors.black87,
        child: Center(
          child: Icon(
            df.type == AttachmentType.video
                ? Icons.videocam
                : df.type == AttachmentType.audio
                ? Icons.audio_file
                : Icons.insert_drive_file,
            color: Colors.white,
            size: 36,
          ),
        ),
      );
    }
    // Local file
    final isVideo = _isVideo(entry.file!.mimeType, entry.file!.path);
    if (isVideo) {
      return Container(
        width: size,
        height: size,
        color: Colors.black87,
        child: const Center(
          child: Icon(Icons.videocam, color: Colors.white, size: 36),
        ),
      );
    }
    return Image.file(
      File(entry.file!.path),
      width: size,
      height: size,
      fit: BoxFit.cover,
    );
  }

  static const _pollDurationOptions = <int, String>{
    300: '5分',
    1800: '30分',
    3600: '1時間',
    21600: '6時間',
    43200: '12時間',
    86400: '1日',
    259200: '3日',
    604800: '7日',
  };

  void _addPollOption() {
    if (_pollControllers.length >= 10) return;
    setState(() => _pollControllers.add(TextEditingController()));
  }

  void _removePollOption(int index) {
    if (_pollControllers.length <= 2) return;
    setState(() {
      _pollControllers[index].dispose();
      _pollControllers.removeAt(index);
    });
  }

  Widget _buildPollEditor() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _pollControllers.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pollControllers[i],
                      decoration: InputDecoration(
                        hintText: '選択肢 ${i + 1}',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  if (_pollControllers.length > 2)
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _sending ? null : () => _removePollOption(i),
                    ),
                ],
              ),
            ),
          Row(
            children: [
              if (_pollControllers.length < 10)
                TextButton.icon(
                  onPressed: _sending ? null : _addPollOption,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('選択肢を追加'),
                ),
              const Spacer(),
              FilterChip(
                label: const Text('複数選択'),
                selected: _pollMultiple,
                onSelected: _sending
                    ? null
                    : (v) => setState(() => _pollMultiple = v),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Row(
            children: [
              const Icon(Icons.timer_outlined, size: 16),
              const SizedBox(width: 4),
              DropdownButton<int>(
                value: _pollExpiresIn,
                underline: const SizedBox.shrink(),
                isDense: true,
                onChanged: _sending
                    ? null
                    : (v) {
                        if (v != null) setState(() => _pollExpiresIn = v);
                      },
                items: _pollDurationOptions.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
              ),
            ],
          ),
        ],
      ),
    );
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
      _controller.text = result.replaceFirst(RegExp(r'^---\n'), '');
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
        final suffix = (program.episodeSuffix?.isNotEmpty ?? false)
            ? program.episodeSuffix!
            : '話';
        tags.add('${program.episode}$suffix');
      }
      if (program.subtitle != null) tags.add(program.subtitle!);
      tags.addAll(program.extraTags);

      final yamlTags = tags.map((t) => '  - $t').join('\n');
      final lines = ['command: user_config', 'tagging:', '  user_tags:'];
      lines.add(yamlTags);
      if (program.minutes != null) {
        lines.add('  minutes: ${program.minutes}');
        lines.add('decoration:');
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

  Future<void> _pickScheduleDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: '予約投稿の日付',
      confirmText: '次へ（時刻を選択）',
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: _scheduledAt != null
          ? TimeOfDay.fromDateTime(_scheduledAt!)
          : TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
      helpText: '予約投稿の時刻',
    );
    if (time == null || !mounted) return;

    final scheduled = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    // Mastodon requires at least 5 minutes in the future.
    final minTime = DateTime.now().add(const Duration(minutes: 5));
    if (scheduled.isBefore(minTime)) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('5分以上先の日時を指定してください')));
      }
      return;
    }
    setState(() => _scheduledAt = scheduled);
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty && !_pollEnabled) return;

    if (_pollEnabled) {
      final filledOptions = _pollControllers
          .map((c) => c.text.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (filledOptions.length < 2) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('選択肢を2つ以上入力してください')));
        return;
      }
    }

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    setState(() => _sending = true);
    try {
      // Upload local attachments / reuse drive file IDs.
      final mediaIds = await Future.wait(
        _attachments.map((entry) async {
          if (entry.isDrive) {
            return entry.driveFile!.id;
          }
          final draft = AttachmentDraft(
            filePath: entry.file!.path,
            description: entry.description.isNotEmpty
                ? entry.description
                : null,
            mimeType: entry.file!.mimeType,
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
          quoteId: widget.quoteTo?.id,
          mediaIds: mediaIds,
          spoilerText: spoilerText?.isNotEmpty == true ? spoilerText : null,
          sensitive: _effectiveSensitive,
          localOnly: _localOnly,
          channelId: widget.channelId,
          scheduledAt: _scheduledAt,
          language: _language,
          pollOptions: _pollEnabled
              ? _pollControllers
                    .map((c) => c.text.trim())
                    .where((t) => t.isNotEmpty)
                    .toList()
              : null,
          pollExpiresIn: _pollEnabled ? _pollExpiresIn : null,
          pollMultiple: _pollEnabled && _pollMultiple,
        ),
      );
      if (mounted) {
        if (_scheduledAt != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('予約投稿を設定しました')));
        } else {
          ref.invalidate(timelineProvider);
          if (widget.channelId != null) {
            ref.invalidate(channelTimelineProvider(widget.channelId!));
          }
        }
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
          widget.replyTo != null
              ? 'リプライ'
              : widget.channelName != null
              ? '${ref.watch(postLabelProvider)}：${widget.channelName}'
              : ref.watch(postLabelProvider),
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
                : Icon(_scheduledAt != null ? Icons.schedule_send : Icons.send),
            tooltip: _scheduledAt != null ? '予約投稿' : null,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.replyTo != null) _ReplyPreview(post: widget.replyTo!),
            if (widget.quoteTo != null) _QuotePreview(post: widget.quoteTo!),
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
            if (_mentionSuggestions.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _mentionSuggestions.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 4),
                  itemBuilder: (context, index) {
                    final user = _mentionSuggestions[index];
                    final localHost = ref
                        .read(currentAccountProvider)
                        ?.user
                        .host;
                    final isRemote =
                        user.host != null && user.host != localHost;
                    final label = isRemote
                        ? '@${_buildAcct(user)}'
                        : '@${user.username}';
                    return ActionChip(
                      avatar: user.isGroup
                          ? const Icon(Icons.groups, size: 18)
                          : user.isBot
                          ? const Icon(Icons.smart_toy, size: 18)
                          : user.avatarUrl != null
                          ? CircleAvatar(
                              backgroundImage: NetworkImage(user.avatarUrl!),
                              radius: 12,
                            )
                          : const Icon(Icons.person, size: 18),
                      label: Text(label, overflow: TextOverflow.ellipsis),
                      tooltip: user.isGroup
                          ? 'コミュニティ: @${_buildAcct(user)}'
                          : '@${_buildAcct(user)}',
                      onPressed: () => _insertMention(user),
                    );
                  },
                ),
              ),
            if (_hashtagSuggestions.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _hashtagSuggestions.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 4),
                  itemBuilder: (context, index) {
                    final tag = _hashtagSuggestions[index];
                    return ActionChip(
                      avatar: const Icon(Icons.tag, size: 18),
                      label: Text('#$tag', overflow: TextOverflow.ellipsis),
                      onPressed: () => _insertHashtag(tag),
                    );
                  },
                ),
              ),
            if (_pollEnabled) ...[const Divider(), _buildPollEditor()],
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
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _sending ? null : () => _editDescription(index),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: _buildThumbnail(entry),
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
                if (ref.watch(currentAdapterProvider) is DriveSupport)
                  IconButton(
                    onPressed: _sending ? null : _pickDriveFiles,
                    icon: const Icon(Icons.cloud_outlined),
                    tooltip: 'ドライブ',
                  ),
                IconButton(
                  onPressed: _sending ? null : _showEmojiPicker,
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  tooltip: '絵文字',
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
                if (ref.watch(currentAdapterProvider) is PollSupport)
                  IconButton(
                    onPressed: _sending
                        ? null
                        : () => setState(() => _pollEnabled = !_pollEnabled),
                    icon: Icon(
                      Icons.poll_outlined,
                      color: _pollEnabled
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    tooltip: 'アンケート',
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
                if (ref.watch(currentAdapterProvider) is ScheduleSupport)
                  IconButton(
                    onPressed: _sending ? null : _pickScheduleDate,
                    icon: Icon(
                      Icons.schedule,
                      color: _scheduledAt != null
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    tooltip: '予約投稿',
                  ),
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
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
                  if (ref.watch(currentAdapterProvider) is ReactionSupport)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: FilterChip(
                        label: const Text('ローカルのみ'),
                        selected: _localOnly,
                        onSelected: _sending
                            ? null
                            : (v) => setState(() => _localOnly = v),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  if (_language != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: DropdownButton<String>(
                        value: _language,
                        underline: const SizedBox.shrink(),
                        isDense: true,
                        onChanged: _sending
                            ? null
                            : (v) {
                                if (v != null) setState(() => _language = v);
                              },
                        items: _languageOptions.entries
                            .map(
                              (e) => DropdownMenuItem(
                                value: e.key,
                                child: Text(
                                  e.value,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  if (_scheduledAt != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Chip(
                        avatar: const Icon(Icons.schedule, size: 16),
                        label: Text(
                          '${_scheduledAt!.month}/${_scheduledAt!.day} '
                          '${_scheduledAt!.hour.toString().padLeft(2, '0')}:'
                          '${_scheduledAt!.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onDeleted: _sending
                            ? null
                            : () => setState(() => _scheduledAt = null),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
            if (maxLength != null)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ValueListenableBuilder<TextEditingValue>(
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
                ),
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
                  fallbackHost: post.emojiHost,
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

class _QuotePreview extends StatelessWidget {
  final Post post;

  const _QuotePreview({required this.post});

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
            Icons.format_quote,
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
                  fallbackHost: post.emojiHost,
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
      final suffix = (p.episodeSuffix?.isNotEmpty ?? false)
          ? p.episodeSuffix!
          : '話';
      parts.add('${p.episode}$suffix');
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
