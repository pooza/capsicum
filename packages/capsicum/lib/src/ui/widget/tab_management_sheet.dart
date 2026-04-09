import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/hashtag_provider.dart';
import '../../provider/preferences_provider.dart';

class TabManagementSheet extends ConsumerStatefulWidget {
  final String storageKey;
  final List<PostList> allLists;
  final Set<TimelineType> supportedTimelines;
  final bool isMastodon;

  const TabManagementSheet({
    super.key,
    required this.storageKey,
    required this.allLists,
    required this.supportedTimelines,
    this.isMastodon = false,
  });

  @override
  ConsumerState<TabManagementSheet> createState() => _TabManagementSheetState();
}

class _TabManagementSheetState extends ConsumerState<TabManagementSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _addHashtag() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    ref.read(pinnedHashtagsProvider(widget.storageKey).notifier).add(text);
    _controller.clear();
  }

  void _showAndTagDialog(BuildContext context, String currentSpec) {
    final (primary, existingAll) = parseHashtagSpec(currentSpec);
    final andController = TextEditingController(
      text: existingAll?.join(', ') ?? '',
    );

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('#$primary のAND条件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AND条件で絞り込むタグをカンマ区切りで入力してください。'),
            const Text('空にするとAND条件を解除します。'),
            const SizedBox(height: 12),
            TextField(
              controller: andController,
              decoration: const InputDecoration(
                hintText: '例: nitiasa, precure',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              final input = andController.text.trim();
              final andTags = input.isEmpty
                  ? <String>[]
                  : input
                        .split(RegExp(r'[,、\s]+'))
                        .map((t) => t.replaceFirst(RegExp('^#'), '').trim())
                        .where((t) => t.isNotEmpty)
                        .toList();
              final newSpec = andTags.isEmpty
                  ? primary
                  : '$primary+${andTags.join('+')}';
              ref
                  .read(pinnedHashtagsProvider(widget.storageKey).notifier)
                  .replace(currentSpec, newSpec);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  List<PostList> _sortedLists() {
    final order = ref.watch(listOrderProvider(widget.storageKey));
    final sorted = [...widget.allLists];
    if (order.isNotEmpty) {
      sorted.sort((a, b) {
        final ai = order.indexOf(a.id);
        final bi = order.indexOf(b.id);
        if (ai == -1 && bi == -1) return 0;
        if (ai == -1) return 1;
        if (bi == -1) return -1;
        return ai.compareTo(bi);
      });
    }
    return sorted;
  }

  void _reorderLists(int oldIndex, int newIndex) {
    final lists = _sortedLists();
    if (newIndex > oldIndex) newIndex--;
    final item = lists.removeAt(oldIndex);
    lists.insert(newIndex, item);
    ref
        .read(listOrderProvider(widget.storageKey).notifier)
        .setOrder(lists.map((l) => l.id).toList());
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      margin: const EdgeInsets.only(top: 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  static const _timelineLabels = {
    TimelineType.home: 'ホーム',
    TimelineType.local: 'ローカル',
    TimelineType.social: 'ソーシャル',
    TimelineType.federated: 'グローバル',
    TimelineType.directMessages: 'DM',
  };

  static const _mastodonLabelOverrides = {TimelineType.federated: '連合'};

  String _timelineLabel(TimelineType type) {
    if (widget.isMastodon) {
      return _mastodonLabelOverrides[type] ??
          _timelineLabels[type] ??
          type.name;
    }
    return _timelineLabels[type] ?? type.name;
  }

  void _reorderTimelines(int oldIndex, int newIndex) {
    final order = ref.read(tabOrderProvider(widget.storageKey));
    final types = order.where(widget.supportedTimelines.contains).toList();
    if (newIndex > oldIndex) newIndex--;
    final item = types.removeAt(oldIndex);
    types.insert(newIndex, item);
    ref.read(tabOrderProvider(widget.storageKey).notifier).setOrder(types);
  }

  Widget _buildTimelineTypesSection(ThemeData theme) {
    final hiddenTypes = ref.watch(
      hiddenTimelineTypesProvider(widget.storageKey),
    );
    final order = ref.watch(tabOrderProvider(widget.storageKey));
    final types = order.where(widget.supportedTimelines.contains).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(theme, '基本タブ'),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: types.length,
          onReorder: _reorderTimelines,
          itemBuilder: (context, index) {
            final type = types[index];
            final hidden = hiddenTypes.contains(type);
            return ListTile(
              key: ValueKey(type),
              leading: ReorderableDragStartListener(
                index: index,
                child: const Icon(Icons.drag_handle),
              ),
              title: Text(
                _timelineLabel(type),
                style: hidden ? TextStyle(color: theme.disabledColor) : null,
              ),
              trailing: IconButton(
                icon: Icon(hidden ? Icons.visibility_off : Icons.visibility),
                onPressed: () => ref
                    .read(
                      hiddenTimelineTypesProvider(widget.storageKey).notifier,
                    )
                    .toggle(type),
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hiddenIds = ref.watch(hiddenListIdsProvider(widget.storageKey));
    final lists = _sortedLists();
    final tags = ref.watch(pinnedHashtagsProvider(widget.storageKey));
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text('タブ管理', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // --- Timeline types section ---
                  _buildTimelineTypesSection(theme),
                  // --- Lists section ---
                  _sectionHeader(theme, 'リスト'),
                  if (lists.isNotEmpty)
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      itemCount: lists.length,
                      onReorder: _reorderLists,
                      itemBuilder: (context, index) {
                        final list = lists[index];
                        final hidden = hiddenIds.contains(list.id);
                        return ListTile(
                          key: ValueKey('list-${list.id}'),
                          leading: ReorderableDragStartListener(
                            index: index,
                            child: const Icon(Icons.drag_handle),
                          ),
                          title: Text(
                            list.title,
                            style: hidden
                                ? TextStyle(color: theme.disabledColor)
                                : null,
                          ),
                          trailing: IconButton(
                            icon: Icon(
                              hidden ? Icons.visibility_off : Icons.visibility,
                            ),
                            onPressed: () => ref
                                .read(
                                  hiddenListIdsProvider(
                                    widget.storageKey,
                                  ).notifier,
                                )
                                .toggle(list.id),
                          ),
                        );
                      },
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextButton.icon(
                      icon: const Icon(Icons.edit_note, size: 18),
                      label: const Text('リスト管理'),
                      onPressed: () {
                        Navigator.pop(context);
                        context.push('/lists/manage');
                      },
                    ),
                  ),
                  // --- Hashtags section ---
                  _sectionHeader(theme, 'ハッシュタグ'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            decoration: const InputDecoration(
                              hintText: 'ハッシュタグを入力',
                              prefixText: '#',
                              isDense: true,
                            ),
                            onSubmitted: (_) => _addHashtag(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: _addHashtag,
                        ),
                      ],
                    ),
                  ),
                  if (widget.isMastodon)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'タップでAND条件のタグを追加できます',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (tags.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('ピン留めされたハッシュタグはありません'),
                    )
                  else
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      itemCount: tags.length,
                      onReorder: (oldIndex, newIndex) {
                        ref
                            .read(
                              pinnedHashtagsProvider(
                                widget.storageKey,
                              ).notifier,
                            )
                            .reorder(oldIndex, newIndex);
                      },
                      itemBuilder: (context, index) {
                        final tag = tags[index];
                        return ListTile(
                          key: ValueKey('tag-$tag'),
                          leading: ReorderableDragStartListener(
                            index: index,
                            child: const Icon(Icons.drag_handle),
                          ),
                          title: Text(hashtagSpecLabel(tag)),
                          onTap: widget.isMastodon
                              ? () => _showAndTagDialog(context, tag)
                              : null,
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              ref
                                  .read(
                                    pinnedHashtagsProvider(
                                      widget.storageKey,
                                    ).notifier,
                                  )
                                  .remove(tag);
                            },
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
