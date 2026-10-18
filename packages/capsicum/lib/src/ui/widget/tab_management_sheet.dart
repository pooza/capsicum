import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../util/post_scope_display.dart';
import 'hashtag_condition_dialog.dart';

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
  void initState() {
    super.initState();
    // Sync server lists / followed channels into tab config after the
    // current frame, and again whenever each set changes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ⚠ 開くたびに取り直す (#1156)。デッキのカラム編集シートと同じ理由で、
      // followedChannelsProvider は自分では古くならない。
      ref.invalidate(listsProvider);
      ref.invalidate(followedChannelsProvider);
      _syncLists();
      _syncChannels();
      ref.listenManual(listsProvider, (_, _) {
        _syncLists();
      });
      ref.listenManual(followedChannelsProvider, (_, _) {
        _syncChannels();
      });
    });
  }

  void _syncLists() {
    if (!mounted) return;
    final allEntries = ref.read(tabConfigProvider(widget.storageKey));
    final allLists = ref.read(listsProvider).valueOrNull ?? [];
    final notifier = _notifier;
    for (final list in allLists) {
      final tab = ListTab(id: list.id, name: list.title);
      if (!allEntries.any((e) => e.tab == tab)) {
        notifier.addTab(tab);
      }
      notifier.syncListName(list.id, list.title);
    }
  }

  void _syncChannels() {
    if (!mounted) return;
    final allEntries = ref.read(tabConfigProvider(widget.storageKey));
    final channels = ref.read(followedChannelsProvider).valueOrNull ?? const [];
    final notifier = _notifier;
    for (final ch in channels) {
      final tab = ChannelTab(id: ch.id, name: ch.name);
      if (!allEntries.any((e) => e.tab == tab)) {
        notifier.addTab(tab);
      }
    }
  }

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
    // ⚠ 入力欄では `+` が AND の区切り (#1158)。組み立ては 1 箇所へ (#1159)。
    final spec = hashtagSpecFromTags(text.split('+'));
    if (spec.isEmpty) return;
    _notifier.addTab(HashtagTab(spec));
    _controller.clear();
  }

  /// タグの条件（すべて含む / いずれかを含む / 含まない）を直す (#1209)。
  ///
  /// ⚠ 以前は Mastodon でだけ開けた（AND 条件のダイアログ）。Misskey も OR と
  /// AND をサーバーが受けるので、両方で開く。
  Future<void> _editHashtagCondition(String currentSpec) async {
    final newSpec = await showHashtagConditionDialog(context, currentSpec);
    if (newSpec == null || newSpec == currentSpec) return;
    _notifier.replaceTab(HashtagTab(currentSpec), HashtagTab(newSpec));
  }

  void _reorderEntries(int oldIndex, int newIndex) {
    // The UI shows a filtered list, so we need to map the filtered indices
    // back to the full config list for reordering.
    final all = ref.read(tabConfigProvider(widget.storageKey));
    final filtered = _filteredEntries();
    if (oldIndex >= filtered.length) return;

    // onReorderItem は削除後の挿入位置として newIndex を渡してくるため、
    // 旧 onReorder のような -1 補正は不要 (#836)。
    if (newIndex >= filtered.length) newIndex = filtered.length - 1;

    final movedEntry = filtered[oldIndex];
    final targetEntry = filtered[newIndex];

    // Find positions in the full list.
    final fullOld = all.indexOf(movedEntry);
    final fullNew = all.indexOf(targetEntry);
    if (fullOld < 0 || fullNew < 0) return;

    final result = [...all];
    result.removeAt(fullOld);
    // After removal, adjust target index if it was after the removed item.
    final adjustedNew = fullNew > fullOld ? fullNew - 1 : fullNew;
    // Insert after or at the target depending on direction.
    final insertAt = newIndex >= oldIndex ? adjustedNew + 1 : adjustedNew;
    result.insert(insertAt.clamp(0, result.length), movedEntry);
    _notifier.setOrder(result);
  }

  /// Returns the filtered entries matching what the UI displays.
  List<TabConfigEntry> _filteredEntries() {
    final adapter = ref.read(currentAdapterProvider);
    final supported =
        adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final allLists = ref.read(listsProvider).valueOrNull ?? [];
    final serverListIds = allLists.map((l) => l.id).toSet();
    final channels = ref.read(followedChannelsProvider).valueOrNull ?? const [];
    final followedChannelIds = channels.map((c) => c.id).toSet();
    return ref.read(tabConfigProvider(widget.storageKey)).where((e) {
      if (e.tab is TimelineTab) {
        return supported.contains((e.tab as TimelineTab).type);
      }
      if (e.tab is ListTab) {
        return serverListIds.contains((e.tab as ListTab).id);
      }
      if (e.tab is ChannelTab) {
        return followedChannelIds.contains((e.tab as ChannelTab).id);
      }
      if (e.tab is MessagesTab) {
        // ChatSupport / canReadChat を満たすアダプタでのみ表示 (#439)。
        return adapter is ChatSupport && (adapter as ChatSupport).canReadChat;
      }
      return true;
    }).toList();
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
    TimelineType.remote: '連合（リモートのみ）',
  };

  static const _mastodonLabelOverrides = {TimelineType.federated: '連合'};

  String _tabEntryLabel(TabType tab) {
    return switch (tab) {
      TimelineTab(:final type) => () {
        if (type == TimelineType.local) {
          return ref.watch(localTimelineNameProvider);
        }
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
      // ⚠ 名前なしで保存されたタブは一覧から引く (#1296)。この画面はフォロー中の
      // チャンネルしか出さないので、1 件取得は要らない。
      ChannelTab(:final name, :final id) =>
        name ??
            ref
                .watch(followedChannelsProvider)
                .valueOrNull
                ?.where((c) => c.id == id)
                .firstOrNull
                ?.name ??
            id,
      NotificationsTab() => '通知',
      AnnouncementsTab() => 'お知らせ',
      MessagesTab() => 'メッセージ',
      // デッキのカラム専用 (#1148)。タブ管理には出ない。
      DeckOnlyTab() => 'デッキ専用',
    };
  }

  IconData _tabEntryIcon(TabType tab) {
    return switch (tab) {
      TimelineTab() => Icons.forum_outlined,
      ListTab() => Icons.list,
      HashtagTab() => Icons.tag,
      ChannelTab() => Icons.forum,
      NotificationsTab() => Icons.notifications_outlined,
      AnnouncementsTab() => Icons.campaign_outlined,
      MessagesTab() => Icons.chat_bubble_outline,
      DeckOnlyTab() => Icons.view_column_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(currentAdapterProvider);
    final supported =
        adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final allEntries = ref.watch(tabConfigProvider(widget.storageKey));
    final allLists = ref.watch(listsProvider).valueOrNull ?? [];
    final serverListIds = allLists.map((l) => l.id).toSet();
    final channels =
        ref.watch(followedChannelsProvider).valueOrNull ?? const [];
    final followedChannelIds = channels.map((c) => c.id).toSet();

    // Filter out unsupported timeline types, deleted lists, and unfollowed
    // channels.
    final entries = allEntries.where((e) {
      if (e.tab is TimelineTab) {
        return supported.contains((e.tab as TimelineTab).type);
      }
      if (e.tab is ListTab) {
        return serverListIds.contains((e.tab as ListTab).id);
      }
      if (e.tab is ChannelTab) {
        return followedChannelIds.contains((e.tab as ChannelTab).id);
      }
      if (e.tab is MessagesTab) {
        return adapter is ChatSupport && (adapter as ChatSupport).canReadChat;
      }
      return true;
    }).toList();
    final theme = Theme.of(context);

    // Split hashtag entries for the add-hashtag input section.
    final hasHashtags = entries.any((e) => e.tab is HashtagTab);

    return Padding(
      // ⚠ キーボードとナビゲーションバーの両方を足す (#1062)。二重には入らない
      // （キーボードが覆っている間は `padding.bottom` が 0 になる）。
      padding: EdgeInsets.only(
        bottom:
            MediaQuery.viewInsetsOf(context).bottom +
            MediaQuery.paddingOf(context).bottom,
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
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
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
                    onReorderItem: _reorderEntries,
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
                              color: entry.visible ? null : theme.disabledColor,
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
                        onTap: tab is HashtagTab
                            ? () => _editHashtagCondition(tab.tag)
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Delete button for removable tabs (hashtags).
                            if (tab is HashtagTab)
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'このタブを削除',
                                onPressed: () => _notifier.removeTab(tab),
                              ),
                            // Visibility toggle.
                            IconButton(
                              icon: Icon(
                                entry.visible
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                              // ⚠ アイコンは**いまの状態**。押した結果を言葉で
                              // 添える（どちらなのかが絵からは読めない・#1197）。
                              tooltip: entry.visible ? 'タブを隠す' : 'タブを表示する',
                              onPressed: () => _notifier.toggleVisibility(tab),
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
                              // ⚠ デッキのカラム編集と同じ文言にする (#1158)。
                              helperText: kHashtagAndHelperText,
                              helperMaxLines: 2,
                              prefixText: '#',
                              isDense: true,
                            ),
                            onSubmitted: (_) => _addHashtag(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: 'ハッシュタグのタブを追加',
                          onPressed: _addHashtag,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'タグのタブを押すと、条件（すべて含む / いずれかを含む / 含まない）を'
                      '変えられます',
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
