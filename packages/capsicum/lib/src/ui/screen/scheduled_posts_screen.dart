import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';

final _scheduledPostsProvider = FutureProvider.autoDispose<List<ScheduledPost>>(
  (ref) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! ScheduleSupport) return [];
    return (adapter as ScheduleSupport).getScheduledPosts();
  },
);

class ScheduledPostsScreen extends ConsumerWidget {
  const ScheduledPostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final postsAsync = ref.watch(_scheduledPostsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('予約投稿')),
      body: postsAsync.when(
        data: (posts) {
          if (posts.isEmpty) {
            return const Center(child: Text('予約投稿はありません'));
          }
          return ListView.builder(
            itemCount: posts.length,
            itemBuilder: (context, index) {
              final post = posts[index];
              return _ScheduledPostTile(
                post: post,
                onEditTags: () => _showTagEditor(context, ref, post),
                onCancel: () => _confirmCancel(context, ref, post),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('読み込みに失敗しました\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(_scheduledPostsProvider),
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmCancel(
    BuildContext context,
    WidgetRef ref,
    ScheduledPost post,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('予約投稿の取り消し'),
        content: const Text('この予約投稿を取り消しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取り消す'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter is ScheduleSupport) {
      try {
        await (adapter as ScheduleSupport).cancelScheduledPost(post.id);
        ref.invalidate(_scheduledPostsProvider);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('予約投稿を取り消しました')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('取り消しに失敗しました')));
        }
      }
    }
  }

  void _showTagEditor(BuildContext context, WidgetRef ref, ScheduledPost post) {
    final adapter = ref.read(currentAdapterProvider);
    final account = ref.read(currentAccountProvider);
    final mulukhiya = account?.mulukhiya;

    // Mastodon + mulukhiya: use tag editing API
    // Misskey: update draft text directly
    final isMastodon = adapter is! ReactionSupport;
    final canEditViaMulukhiya = isMastodon && mulukhiya != null;
    final canEditViaMisskey = !isMastodon;

    if (!canEditViaMulukhiya && !canEditViaMisskey) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('タグ編集にはモロヘイヤが必要です')));
      return;
    }

    // Collect protected default hashtags from mulukhiya.
    final protectedTags = <String>{};
    if (mulukhiya != null) {
      if (mulukhiya.defaultHashtag != null) {
        protectedTags.add(mulukhiya.defaultHashtag!);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _TagEditorSheet(
        content: post.content ?? '',
        protectedTags: protectedTags,
        onSave: (tags) async {
          Navigator.pop(sheetContext);
          try {
            if (canEditViaMulukhiya) {
              await mulukhiya.updateScheduledStatusTags(
                accessToken: account!.userSecret.accessToken,
                id: post.id,
                tags: tags,
              );
            } else if (canEditViaMisskey) {
              final misskeyAdapter = adapter as MisskeyAdapter;
              final newText = _replaceTagsInText(post.content ?? '', tags);
              await misskeyAdapter.client.updateScheduledNote(
                draftId: post.id,
                text: newText,
                scheduledAt: post.scheduledAt,
              );
            }
            ref.invalidate(_scheduledPostsProvider);
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('タグを更新しました')));
            }
          } catch (e) {
            var message = 'タグの更新に失敗しました';
            if (e is DioException) {
              final status = e.response?.statusCode;
              final body = e.response?.data;
              final detail = body is Map
                  ? body['error'] ?? body.toString()
                  : '$body';
              message = '$message ($status: $detail)';
              debugPrint('Tag update error: $status $detail');
            } else {
              message = '$message: $e';
            }
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(message)));
            }
          }
        },
      ),
    );
  }

  /// Replace hashtags in text content with new tag list.
  /// Preserves non-tag text and replaces trailing hashtag block.
  static String _replaceTagsInText(String text, List<String> tags) {
    // Split into body (non-hashtag lines) and trailing hashtags.
    final lines = text.split('\n');
    final bodyLines = <String>[];
    final trailingTagLines = <String>[];
    bool inTrailingTags = false;

    // Walk from the end to find trailing hashtag block.
    for (int i = lines.length - 1; i >= 0; i--) {
      final trimmed = lines[i].trim();
      if (!inTrailingTags) {
        if (trimmed.isEmpty || _isHashtagLine(trimmed)) {
          inTrailingTags = true;
          if (trimmed.isNotEmpty) trailingTagLines.add(trimmed);
        } else {
          break;
        }
      } else {
        if (_isHashtagLine(trimmed) || trimmed.isEmpty) {
          if (trimmed.isNotEmpty) trailingTagLines.add(trimmed);
        } else {
          break;
        }
      }
    }

    final bodyEndIndex =
        lines.length -
        trailingTagLines.length -
        // Count trailing empty lines between body and tags
        lines
            .sublist(
              lines.length - trailingTagLines.length - 1 >= 0
                  ? lines.length - trailingTagLines.length - 1
                  : 0,
            )
            .takeWhile((l) => l.trim().isEmpty)
            .length;
    bodyLines.addAll(lines.sublist(0, bodyEndIndex.clamp(0, lines.length)));

    // Remove trailing empty lines from body.
    while (bodyLines.isNotEmpty && bodyLines.last.trim().isEmpty) {
      bodyLines.removeLast();
    }

    final body = bodyLines.join('\n');
    if (tags.isEmpty) return body;
    final tagStr = tags.map((t) => t.startsWith('#') ? t : '#$t').join(' ');
    return body.isEmpty ? tagStr : '$body\n\n$tagStr';
  }

  static bool _isHashtagLine(String line) {
    return line
        .split(RegExp(r'\s+'))
        .every((word) => word.startsWith('#') && word.length > 1);
  }
}

class _ScheduledPostTile extends StatelessWidget {
  final ScheduledPost post;
  final VoidCallback onEditTags;
  final VoidCallback onCancel;

  const _ScheduledPostTile({
    required this.post,
    required this.onEditTags,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final dt = post.scheduledAt.toLocal();
    final dateStr =
        '${dt.year}/${dt.month}/${dt.day} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';

    return ListTile(
      title: Text(
        post.content ?? '（本文なし）',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(dateStr),
      leading: const Icon(Icons.schedule),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.tag),
            tooltip: 'タグ編集',
            onPressed: onEditTags,
          ),
          IconButton(
            icon: const Icon(Icons.cancel_outlined),
            tooltip: '取り消す',
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// Extracts hashtags from post content.
List<String> _extractTags(String content) {
  final tagPattern = RegExp(r'#(\S+)');
  return tagPattern
      .allMatches(content)
      .map((m) => m.group(1)!)
      .toSet()
      .toList();
}

class _TagEditorSheet extends StatefulWidget {
  final String content;
  final Set<String> protectedTags;
  final Future<void> Function(List<String> tags) onSave;

  const _TagEditorSheet({
    required this.content,
    this.protectedTags = const {},
    required this.onSave,
  });

  @override
  State<_TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<_TagEditorSheet> {
  late List<String> _tags;
  final _controller = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tags = _extractTags(widget.content);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _addTag() {
    final tag = _controller.text.trim().replaceFirst('#', '');
    if (tag.isEmpty || _tags.contains(tag)) return;
    setState(() {
      _tags.add(tag);
      _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('タグ編集', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: _tags.map((tag) {
              final isProtected = widget.protectedTags.contains(tag);
              return Chip(
                label: Text('#$tag'),
                onDeleted: isProtected
                    ? null
                    : () => setState(() => _tags.remove(tag)),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: 'タグを追加',
                    isDense: true,
                    prefixText: '#',
                  ),
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(icon: const Icon(Icons.add), onPressed: _addTag),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving
                  ? null
                  : () async {
                      setState(() => _saving = true);
                      await widget.onSave(_tags);
                    },
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}
