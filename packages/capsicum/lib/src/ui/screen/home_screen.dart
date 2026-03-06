import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/timeline_provider.dart';
import '../widget/emoji_text.dart';
import '../widget/post_tile.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(timelineProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    final accountState = ref.watch(accountManagerProvider);
    final selectedType = ref.watch(selectedTimelineTypeProvider);
    final timeline = ref.watch(timelineProvider);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            if (account?.user.avatarUrl != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    account!.user.avatarUrl!,
                    width: 28,
                    height: 28,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  EmojiText(
                    account?.user.displayName ?? account?.user.username ?? '',
                    emojis: account?.user.emojis ?? const {},
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Tooltip(
                    message: '@${account?.user.username ?? ""}@${account?.key.host ?? ""}',
                    child: Text(
                      '@${account?.user.username ?? ""}@${account?.key.host ?? ""}',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () => context.push('/notifications'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _buildTimelineTabs(context, selectedType),
        ),
      ),
      drawer: _buildDrawer(context, ref, account, accountState),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/compose'),
        child: const Icon(Icons.edit),
      ),
      body: timeline.when(
        data: (tlState) => RefreshIndicator(
          onRefresh: () => ref.refresh(timelineProvider.future),
          child: ListView.separated(
            controller: _scrollController,
            itemCount: tlState.posts.length + (tlState.isLoadingMore ? 1 : 0),
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index >= tlState.posts.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return PostTile(post: tlState.posts[index]);
            },
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('タイムラインの読み込みに失敗しました\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(timelineProvider),
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
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

  /// Mastodon uses "連合" instead of "グローバル".
  static const _mastodonLabelOverrides = {TimelineType.federated: '連合'};

  Widget _buildTimelineTabs(BuildContext context, TimelineType selected) {
    final adapter = ref.watch(currentAdapterProvider);
    final supported =
        adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final isMastodon = !supported.contains(TimelineType.social);

    // Maintain consistent ordering.
    const order = [
      TimelineType.home,
      TimelineType.local,
      TimelineType.social,
      TimelineType.federated,
    ];
    final tabs = order.where(supported.contains).toList();

    return Row(
      children: tabs.map((type) {
        var label =
            (isMastodon ? _mastodonLabelOverrides[type] : null) ??
            _timelineLabels[type] ??
            type.name;
        if (type == TimelineType.local) {
          label = ref.watch(localTimelineNameProvider);
        }
        return _tabButton(context, label, type, selected);
      }).toList(),
    );
  }

  Widget _tabButton(
    BuildContext context,
    String label,
    TimelineType type,
    TimelineType selected,
  ) {
    final isSelected = type == selected;
    final colorScheme = Theme.of(context).colorScheme;

    return Expanded(
      child: InkWell(
        onTap: () {
          ref.read(selectedTimelineTypeProvider.notifier).state = type;
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? colorScheme.primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDrawer(
    BuildContext context,
    WidgetRef ref,
    Account? current,
    AccountManagerState accountState,
  ) {
    final otherAccounts = accountState.accounts
        .where((a) => a.key != current?.key)
        .toList();

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          UserAccountsDrawerHeader(
            accountName: EmojiText(
              current?.user.displayName ?? current?.user.username ?? '',
              emojis: current?.user.emojis ?? const {},
              style: const TextStyle(color: Colors.black),
            ),
            accountEmail: Text(
              '@${current?.user.username ?? ""}@${current?.key.host ?? ""}',
              style: const TextStyle(color: Colors.black),
            ),
            currentAccountPicture: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: current?.user.avatarUrl != null
                  ? Image.network(
                      current!.user.avatarUrl!,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      width: 72,
                      height: 72,
                      color: Theme.of(context).colorScheme.primary,
                      alignment: Alignment.center,
                      child: Text(
                        (current?.user.username ?? '?')[0].toUpperCase(),
                        style: const TextStyle(
                          fontSize: 24,
                          color: Colors.white,
                        ),
                      ),
                    ),
            ),
            onDetailsPressed: current != null
                ? () {
                    Navigator.of(context).pop();
                    context.push('/profile', extra: current.user);
                  }
                : null,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
          ),
          if (otherAccounts.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'アカウント切替',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            ...otherAccounts.map(
              (account) => ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: account.user.avatarUrl != null
                      ? Image.network(
                          account.user.avatarUrl!,
                          width: 32,
                          height: 32,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          width: 32,
                          height: 32,
                          color: Theme.of(context).colorScheme.primaryContainer,
                          alignment: Alignment.center,
                          child: Text(account.user.username[0].toUpperCase()),
                        ),
                ),
                title: EmojiText(
                  account.user.displayName ?? account.user.username,
                  emojis: account.user.emojis,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '@${account.user.username}@${account.key.host}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  ref
                      .read(accountManagerProvider.notifier)
                      .switchAccount(account);
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.person_add),
            title: const Text('アカウントを追加'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/server');
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('検索'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/search');
            },
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('通知'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/notifications');
            },
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: Text(
              ref.read(currentAdapterProvider) is ReactionSupport
                  ? 'お気に入り'
                  : 'ブックマーク',
            ),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/bookmarks');
            },
          ),
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('お知らせ'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/announcements');
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('ログアウト'),
            onTap: () async {
              Navigator.of(context).pop();
              if (current == null) return;

              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('ログアウト'),
                  content: Text(
                    '@${current.user.username}@${current.key.host} '
                    'からログアウトしますか？',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('キャンセル'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('ログアウト'),
                    ),
                  ],
                ),
              );

              if (confirmed == true) {
                await ref.read(accountManagerProvider.notifier).logout(current);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('capsicum について'),
            onTap: () {
              Navigator.of(context).pop();
              showAboutDialog(
                context: context,
                applicationName: 'capsicum',
                applicationLegalese: 'Mastodon / Misskey クライアント',
              );
            },
          ),
          const Divider(),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const SizedBox.shrink();
              final info = snapshot.data!;
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (current != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${current.key.host} (${current.key.type.displayName})',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ),
                    Text(
                      'capsicum v${info.version} (${info.buildNumber})',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
