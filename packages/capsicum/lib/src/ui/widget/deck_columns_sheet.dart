import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account_key.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/preferences_provider.dart';
import '../util/deck_tabs.dart';
import 'home_menu.dart' show tabLabel;

/// デッキのカラムを追加・並べ替え・削除するシート (#1093)。
///
/// ⚠ **「タブ管理」の一般化**（`docs/deck-ui-plan.md` 決定済み事項 6-1）。
/// `TabManagementSheet` と同じ「並べ替えできるリスト + 追加欄」の形で、新しい UI
/// パターンを持ち込まない。違いは 3 つ:
///
/// - ⚠⚠ **同じカラムを重複して足せる**（6-2）。並べ替え・削除は**列内の id** で
///   指す。**中身（アカウント + 種別）でも index でも指さない**
/// - ⚠⚠ **削除で購読を止めない**（6-3）。重複カラムは provider を共有するので、
///   1 本消して止めるともう 1 本が無音で止まる。最後の 1 本が消えたときに
///   autoDispose が片づける
/// - **カラムごとにアカウントを選べる**（#1096）。候補とラベルは、そのアカウントの
///   スコープで解決する（リスト名・ローカルの呼称はアカウントごとに違う）
class DeckColumnsSheet extends ConsumerStatefulWidget {
  const DeckColumnsSheet({super.key});

  @override
  ConsumerState<DeckColumnsSheet> createState() => _DeckColumnsSheetState();
}

class _DeckColumnsSheetState extends ConsumerState<DeckColumnsSheet> {
  /// カラムを足すアカウント。null なら現在のアカウント。
  AccountKey? _selectedAccount;

  @override
  void initState() {
    super.initState();
    // ⚠⚠ 開くたびにリスト / チャンネルを取り直す (#1156)。followedChannelsProvider
    // は autoDispose を付けられない（[visibleTabsProvider] が常時 watch している）
    // ので、放っておくと **アプリを再起動するまで更新されない**。サーバーで
    // チャンネルをフォローしても候補に出てこなかった。
    // ⚠ build の外で呼ぶ（provider の変更を build 中に起こさない）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(listsProvider);
      ref.invalidate(followedChannelsProvider);
    });
  }

  Widget _sectionHeader(ThemeData theme, String title) =>
      _DeckSheetSectionHeader(title: title);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notifier = ref.read(deckColumnsProvider.notifier);
    final columns = ref.watch(deckColumnsProvider);
    final accounts = ref.watch(accountManagerProvider).accounts;
    final currentKey = ref.watch(currentAccountKeyProvider);
    final selected = accounts.any((a) => a.key == _selectedAccount)
        ? _selectedAccount
        : currentKey;

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
                        notifier.move(columns[oldIndex].id, newIndex),
                    itemBuilder: (context, index) {
                      final column = columns[index];
                      return ListTile(
                        // ⚠ 列内の id をキーにする。重複カラムは中身が同じ。
                        key: ValueKey(column.id),
                        leading: ReorderableDragStartListener(
                          index: index,
                          child: const Icon(Icons.drag_handle),
                        ),
                        title: DeckAccountScope(
                          account: column.account,
                          child: _TabTitle(tab: column.tab),
                        ),
                        subtitle: Text(
                          '@${column.account.username}@${column.account.host}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'カラムを削除',
                          onPressed: () => notifier.remove(column.id),
                        ),
                      );
                    },
                  ),
                  _sectionHeader(theme, 'カラムを追加'),
                  if (selected == null)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('アカウントがありません'),
                    )
                  else ...[
                    if (accounts.length > 1)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: DropdownButton<AccountKey>(
                          key: const ValueKey('deck-account-selector'),
                          isExpanded: true,
                          value: selected,
                          items: [
                            for (final account in accounts)
                              DropdownMenuItem(
                                value: account.key,
                                child: Text(
                                  '@${account.key.username}@${account.key.host}',
                                ),
                              ),
                          ],
                          onChanged: (key) =>
                              setState(() => _selectedAccount = key),
                        ),
                      ),
                    DeckAccountScope(
                      // ⚠ アカウントを替えたら候補を作り直す（入力欄も含めて）。
                      key: ValueKey(selected),
                      account: selected,
                      child: const _DeckColumnCandidates(),
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

/// [account] のスコープで子を描く (#1096)。現在のアカウントならそのまま。
///
/// ⚠ 子の中の `currentAccountProvider` 系が [account] を指すようになる。
/// デッキ画面のカラムと同じ仕組み（案 S）を、シートの中の小さな部品に使う。
/// 接続されていないアカウントでは上書きしない（ラベルが現在のアカウントの呼称で
/// 出るだけで、何も外へ出さない）。
class DeckAccountScope extends ConsumerWidget {
  const DeckAccountScope({
    super.key,
    required this.account,
    required this.child,
  });

  final AccountKey account;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (account == ref.watch(currentAccountKeyProvider)) return child;
    final resolved = ref
        .watch(accountManagerProvider)
        .accounts
        .where((a) => a.key == account)
        .firstOrNull;
    if (resolved == null) return child;
    return ProviderScope(
      overrides: [currentAccountProvider.overrideWithValue(resolved)],
      child: child,
    );
  }
}

class _DeckSheetSectionHeader extends StatelessWidget {
  const _DeckSheetSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
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
  }
}

IconData _tabIcon(TabType tab) => switch (tab) {
  TimelineTab() => Icons.forum_outlined,
  ListTab() => Icons.list,
  HashtagTab() => Icons.tag,
  ChannelTab() => Icons.forum,
  NotificationsTab() => Icons.notifications_outlined,
  AnnouncementsTab() => Icons.campaign_outlined,
  MessagesTab() => Icons.chat_bubble_outline,
  final DeckOnlyTab t => deckOnlyTabIcon(t),
};

/// 周りのスコープのアカウントで [tab] のラベルを出す。
String _labelInScope(WidgetRef ref, TabType tab) {
  final adapter = ref.watch(currentAdapterProvider);
  final isMastodon =
      adapter != null &&
      !adapter.capabilities.supportedTimelines.contains(TimelineType.social);
  // リスト名はキーに持たない（決定済み事項 4）ので、実行時に一覧から引く。
  // ⚠ リスト以外で一覧の取得を起こさない。
  final lists = tab is ListTab && adapter is ListSupport
      ? ref.watch(listsProvider).valueOrNull ?? const <PostList>[]
      : const <PostList>[];
  return tabLabel(ref, tab, isMastodon, adapter, lists);
}

class _TabTitle extends ConsumerWidget {
  const _TabTitle({required this.tab});

  final TabType tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
    children: [
      Icon(_tabIcon(tab), size: 18),
      const SizedBox(width: 8),
      Expanded(child: Text(_labelInScope(ref, tab))),
    ],
  );
}

/// 周りのスコープのアカウントで足せるカラムの候補と、ハッシュタグの入力欄。
class _DeckColumnCandidates extends ConsumerStatefulWidget {
  const _DeckColumnCandidates();

  @override
  ConsumerState<_DeckColumnCandidates> createState() =>
      _DeckColumnCandidatesState();
}

class _DeckColumnCandidatesState extends ConsumerState<_DeckColumnCandidates> {
  final _hashtagController = TextEditingController();

  @override
  void dispose() {
    _hashtagController.dispose();
    super.dispose();
  }

  void _add(TabType tab) {
    // ⚠ スコープの中なので、選んだアカウントが返る。
    final account = ref.read(currentAccountKeyProvider);
    if (account == null) return;
    ref.read(deckColumnsProvider.notifier).add(account, tab);
  }

  void _addHashtag() {
    final text = _hashtagController.text.trim().replaceFirst(RegExp('^#'), '');
    if (text.isEmpty) return;
    // ⚠ 入力欄では `+` が AND の区切り (#1158)。spec の組み立ては
    // hashtagSpecFromTags に寄せる（空のタグを落とす・#1159）。
    final spec = hashtagSpecFromTags(text.split('+'));
    if (spec.isEmpty) return;
    _add(HashtagTab(spec));
    _hashtagController.clear();
  }

  /// すぐ出せる候補（サーバーへ問い合わせずに決まるもの）。
  ///
  /// ⚠ **メッセージは出さない。**フィードを持たない遷移トリガー (#439) なので
  /// カラムにならない。
  ///
  /// ⚠⚠ **リストとチャンネルはここに混ぜない。**取得を伴うので、読み込み中 /
  /// 失敗 / 0 件を出し分ける必要がある (#1155)。混ぜると `valueOrNull ?? []` で
  /// 3 つとも「行が無い」に潰れ、**入口が無いように見える**。
  List<TabType> _localCandidates() {
    final adapter = ref.watch(currentAdapterProvider);
    final storageKey = ref.watch(currentAccountKeyProvider)?.toStorageKey();
    final supported =
        adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final pinnedHashtags = storageKey == null
        ? const <TabType>[]
        : [
            for (final e in ref.watch(tabConfigProvider(storageKey)))
              if (e.tab is HashtagTab) e.tab,
          ];
    return [
      for (final type in TimelineType.values)
        if (supported.contains(type)) TimelineTab(type),
      const NotificationsTab(),
      const AnnouncementsTab(),
      ...pinnedHashtags,
    ];
  }

  /// 取得を伴う候補の状態表示 (#1155)。
  ///
  /// ⚠ **候補一覧ごと待たせない。**種別・通知・お知らせ・ハッシュタグは即座に
  /// 選べるまま、この節だけが読み込み中 / 失敗を出す。
  List<Widget> _asyncCandidateSection<T>({
    required String noun,
    required AsyncValue<List<T>> async,
    required TabType Function(T) toTab,
    required VoidCallback onRetry,
  }) {
    return async.when(
      data: (items) => items.isEmpty
          ? [
              ListTile(
                key: ValueKey('candidates-empty-$noun'),
                enabled: false,
                leading: const Icon(Icons.remove),
                title: Text('$nounがありません'),
              ),
            ]
          : [for (final item in items) _candidateTile(toTab(item))],
      // ⚠ 「読み込み中」と「0 件」を必ず書き分ける。どちらも行が無いと、
      // 待てば出るのか無いのかが利用者に分からない。
      loading: () => [
        ListTile(
          key: ValueKey('candidates-loading-$noun'),
          enabled: false,
          leading: const SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          title: Text('$nounを読み込んでいます…'),
        ),
      ],
      // ⚠ 失敗したら再試行の手段を出す。無いとシートを開き直すしかない。
      error: (_, _) => [
        ListTile(
          key: ValueKey('candidates-error-$noun'),
          leading: const Icon(Icons.error_outline),
          title: Text('$nounを取得できませんでした'),
          trailing: TextButton(onPressed: onRetry, child: const Text('再試行')),
        ),
      ],
    );
  }

  Widget _candidateTile(TabType tab) => ListTile(
    key: ValueKey('candidate-${tab.toIdentityKey()}'),
    leading: Icon(_tabIcon(tab)),
    title: Text(_labelInScope(ref, tab)),
    trailing: const Icon(Icons.add),
    onTap: () => _add(tab),
  );

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(currentAdapterProvider);
    return Column(
      children: [
        for (final tab in _localCandidates()) _candidateTile(tab),
        if (adapter is ListSupport)
          ..._asyncCandidateSection<PostList>(
            noun: 'リスト',
            async: ref.watch(listsProvider),
            toTab: (l) => ListTab(id: l.id, name: l.title),
            onRetry: () => ref.invalidate(listsProvider),
          ),
        if (adapter is ChannelSupport)
          ..._asyncCandidateSection<Channel>(
            noun: 'チャンネル',
            async: ref.watch(followedChannelsProvider),
            toTab: (c) => ChannelTab(id: c.id, name: c.name),
            onRetry: () => ref.invalidate(followedChannelsProvider),
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
                    // ⚠ AND 指定できることが画面のどこにも書かれておらず、
                    // 入口が無いと受け取られていた (#1158)。
                    helperText: '+ でつなぐと AND（例: nitiasa+precure）',
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
                tooltip: 'ハッシュタグのカラムを追加',
                onPressed: _addHashtag,
              ),
            ],
          ),
        ),
      ],
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
