import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../../provider/preferences_provider.dart';
import '../util/post_scope_display.dart';

class TabManagementSheet extends ConsumerStatefulWidget {
  final String storageKey;
  final bool isMastodon;

  const TabManagementSheet({
    super.key,
    required this.storageKey,
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

  TabConfigNotifier get _notifier =>
      ref.read(tabConfigProvider(widget.storageKey).notifier);

  void _addHashtag() {
    final text = _controller.text.trim().replaceFirst(RegExp('^#'), '');
    if (text.isEmpty) return;
    _notifier.addTab(HashtagTab(text));
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
              _notifier.replaceTab(
                HashtagTab(currentSpec),
                HashtagTab(newSpec),
              );
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _reorderEntries(int oldIndex, int newIndex) {
    final entries = ref.read(tabConfigProvider(widget.storageKey));
    final list = [...entries];
    if (newIndex > oldIndex) newIndex--;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    _notifier.setOrder(list);
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
  };

  static const _mastodonLabelOverrides = {TimelineType.federated: '連合'};

  String _tabEntryLabel(TabType tab) {
    return switch (tab) {
      TimelineTab(:final type) => () {
        if (type == TimelineType.directMessages) {
          return postScopeLabel(PostScope.direct, null);
        }
        if (widget.isMastodon) {
          return _mastodonLabelOverrides[type] ??
              _timelineLabels[type] ??
              type.name;
        }
        return _timelineLabels[type] ?? type.name;
      }(),
      ListTab(:final name, :final id) => name ?? id,
      HashtagTab(:final tag) => hashtagSpecLabel(tag),
      NotificationsTab() => '通知',
      AnnouncementsTab() => 'お知らせ',
    };
  }

  IconData _tabEntryIcon(TabType tab) {
    return switch (tab) {
      TimelineTab() => Icons.forum_outlined,
      ListTab() => Icons.list,
      HashtagTab() => Icons.tag,
      NotificationsTab() => Icons.notifications_outlined,
      AnnouncementsTab() => Icons.campaign_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(currentAdapterProvider);
    final supported = adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final allEntries = ref.watch(tabConfigProvider(widget.storageKey));
    // Filter out timeline types not supported by the adapter.
    final entries = allEntries
        .where((e) =>
            e.tab is! TimelineTab || supported.contains((e.tab as TimelineTab).type))
        .toList();
    final theme = Theme.of(context);

    // Split hashtag entries for the add-hashtag input section.
    final hasHashtags = entries.any((e) => e.tab is HashtagTab);

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
                  _sectionHeader(theme, 'タブ'),
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: entries.length,
                    onReorder: _reorderEntries,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final tab = entry.tab;
                      return ListTile(
                        key: ValueKey(tab.toKey()),
                        leading: ReorderableDragStartListener(
                          index: index,
                          child: const Icon(Icons.drag_handle),
                        ),
                        title: Row(
                          children: [
                            Icon(
                              _tabEntryIcon(tab),
                              size: 18,
                              color: entry.visible
                                  ? null
                                  : theme.disabledColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _tabEntryLabel(tab),
                                style: entry.visible
                                    ? null
                                    : TextStyle(color: theme.disabledColor),
                              ),
                            ),
                          ],
                        ),
                        onTap: tab is HashtagTab && widget.isMastodon
                            ? () => _showAndTagDialog(context, tab.tag)
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Delete button for removable tabs (hashtags).
                            if (tab is HashtagTab)
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _notifier.removeTab(tab),
                              ),
                            // Visibility toggle.
                            IconButton(
                              icon: Icon(
                                entry.visible
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                              onPressed: () =>
                                  _notifier.toggleVisibility(tab),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  // --- Add hashtag ---
                  _sectionHeader(theme, 'ハッシュタグを追加'),
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
                  if (!hasHashtags)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('ピン留めされたハッシュタグはありません'),
                    ),
                  // --- List management link ---
                  const SizedBox(height: 8),
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
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
