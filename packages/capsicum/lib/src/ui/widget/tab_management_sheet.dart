import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/preferences_provider.dart';

class TabManagementSheet extends ConsumerStatefulWidget {
  final String storageKey;
  final List<PostList> allLists;

  const TabManagementSheet({
    super.key,
    required this.storageKey,
    required this.allLists,
  });

  @override
  ConsumerState<TabManagementSheet> createState() =>
      _TabManagementSheetState();
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
                  // --- Lists section ---
                  if (lists.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Text('リスト', style: theme.textTheme.labelLarge),
                    ),
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
                              hidden
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            onPressed: () => ref
                                .read(
                                  hiddenListIdsProvider(widget.storageKey)
                                      .notifier,
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
                  ],
                  // --- Hashtags section ---
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child:
                        Text('ハッシュタグ', style: theme.textTheme.labelLarge),
                  ),
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
                              pinnedHashtagsProvider(widget.storageKey)
                                  .notifier,
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
                          title: Text('#$tag'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              ref
                                  .read(
                                    pinnedHashtagsProvider(widget.storageKey)
                                        .notifier,
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
