import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/preferences_provider.dart';
import 'home_menu.dart' show tabLabel;

/// デッキのカラムを追加・並べ替え・削除するシート (#1093)。
///
/// ⚠ **「タブ管理」の一般化**（`docs/deck-ui-plan.md` 決定済み事項 6-1）。
/// `TabManagementSheet` と同じ「並べ替えできるリスト + 追加欄」の形で、新しい UI
/// パターンを持ち込まない。違いは 2 つ:
///
/// - ⚠⚠ **同じカラムを重複して足せる**（6-2）。並べ替え・削除は**列内の id** で
///   指す。**中身（アカウント + 種別）でも index でも指さない**
/// - ⚠⚠ **削除で購読を止めない**（6-3）。重複カラムは provider を共有するので、
///   1 本消して止めるともう 1 本が無音で止まる。最後の 1 本が消えたときに
///   autoDispose が片づける
///
/// ⚠ フェーズ 2 でカラムごとにアカウントを選べるようにする（#1096）。今は現在の
/// アカウントで足す。
class DeckColumnsSheet extends ConsumerStatefulWidget {
  const DeckColumnsSheet({super.key});

  @override
  ConsumerState<DeckColumnsSheet> createState() => _DeckColumnsSheetState();
}

class _DeckColumnsSheetState extends ConsumerState<DeckColumnsSheet> {
  final _hashtagController = TextEditingController();

  @override
  void dispose() {
    _hashtagController.dispose();
    super.dispose();
  }

  DeckColumnsNotifier get _notifier => ref.read(deckColumnsProvider.notifier);

  void _add(TabType tab) {
    final account = ref.read(currentAccountKeyProvider);
    if (account == null) return;
    _notifier.add(account, tab);
  }

  void _addHashtag() {
    final text = _hashtagController.text.trim().replaceFirst(RegExp('^#'), '');
    if (text.isEmpty) return;
    _add(HashtagTab(text));
    _hashtagController.clear();
  }

  static IconData _icon(TabType tab) => switch (tab) {
    TimelineTab() => Icons.forum_outlined,
    ListTab() => Icons.list,
    HashtagTab() => Icons.tag,
    ChannelTab() => Icons.forum,
    NotificationsTab() => Icons.notifications_outlined,
    AnnouncementsTab() => Icons.campaign_outlined,
    MessagesTab() => Icons.chat_bubble_outline,
  };

  Widget _sectionHeader(ThemeData theme, String title) => Container(
    width: double.infinity,
    color: theme.colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );

  /// 現在のアカウントで足せるカラムの候補。
  ///
  /// ⚠ **メッセージは出さない。**フィードを持たない遷移トリガー (#439) なので
  /// カラムにならない。
  List<TabType> _candidates(
    DecentralizedBackendAdapter? adapter,
    String? storageKey,
  ) {
    final supported =
        adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final pinnedHashtags = storageKey == null
        ? const <TabType>[]
        : [
            for (final e in ref.watch(tabConfigProvider(storageKey)))
              if (e.tab is HashtagTab) e.tab,
          ];
    final lists = adapter is ListSupport
        ? ref.watch(listsProvider).valueOrNull ?? const <PostList>[]
        : const <PostList>[];
    final channels = adapter is ChannelSupport
        ? ref.watch(followedChannelsProvider).valueOrNull ?? const <Channel>[]
        : const <Channel>[];
    return [
      for (final type in TimelineType.values)
        if (supported.contains(type)) TimelineTab(type),
      const NotificationsTab(),
      const AnnouncementsTab(),
      ...pinnedHashtags,
      for (final list in lists) ListTab(id: list.id, name: list.title),
      for (final ch in channels) ChannelTab(id: ch.id, name: ch.name),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final columns = ref.watch(deckColumnsProvider);
    final account = ref.watch(currentAccountProvider);
    final adapter = ref.watch(currentAdapterProvider);
    final isMastodon =
        adapter != null &&
        !adapter.capabilities.supportedTimelines.contains(TimelineType.social);
    final lists = adapter is ListSupport
        ? ref.watch(listsProvider).valueOrNull ?? const <PostList>[]
        : const <PostList>[];
    String label(TabType tab) => tabLabel(ref, tab, isMastodon, adapter, lists);
    final candidates = _candidates(adapter, account?.key.toStorageKey());

    return Padding(
      // ⚠ キーボードとナビゲーションバーの両方を足す (#1062)。
      padding: EdgeInsets.only(
        bottom:
            MediaQuery.viewInsetsOf(context).bottom +
            MediaQuery.paddingOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text('カラム編集', style: theme.textTheme.titleMedium),
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
                  _sectionHeader(theme, 'カラム'),
                  if (columns.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('カラムがありません'),
                    ),
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: columns.length,
                    // onReorderItem は「取り除いたあとの挿入位置」を渡すので、
                    // DeckColumnsNotifier.move と同じ意味 (#836)。
                    onReorderItem: (oldIndex, newIndex) =>
                        _notifier.move(columns[oldIndex].id, newIndex),
                    itemBuilder: (context, index) {
                      final column = columns[index];
                      return ListTile(
                        // ⚠ 列内の id をキーにする。重複カラムは中身が同じ。
                        key: ValueKey(column.id),
                        leading: ReorderableDragStartListener(
                          index: index,
                          child: const Icon(Icons.drag_handle),
                        ),
                        title: Row(
                          children: [
                            Icon(_icon(column.tab), size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(label(column.tab))),
                          ],
                        ),
                        subtitle: Text(
                          '@${column.account.username}@${column.account.host}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'カラムを削除',
                          onPressed: () => _notifier.remove(column.id),
                        ),
                      );
                    },
                  ),
                  _sectionHeader(theme, 'カラムを追加'),
                  if (account == null)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('アカウントがありません'),
                    )
                  else ...[
                    for (final tab in candidates)
                      ListTile(
                        key: ValueKey('candidate-${tab.toIdentityKey()}'),
                        leading: Icon(_icon(tab)),
                        title: Text(label(tab)),
                        trailing: const Icon(Icons.add),
                        onTap: () => _add(tab),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _hashtagController,
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
                            tooltip: 'ハッシュタグのカラムを追加',
                            onPressed: _addHashtag,
                          ),
                        ],
                      ),
                    ),
                  ],
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

/// カラム編集シートを開く。
Future<void> showDeckColumnsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const DeckColumnsSheet(),
    );
