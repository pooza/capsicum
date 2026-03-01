import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/timeline_provider.dart';
import '../widget/post_tile.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    final accountState = ref.watch(accountManagerProvider);
    final timeline = ref.watch(homeTimelineProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('@${account?.user.username ?? ""}'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      drawer: _buildDrawer(context, ref, account, accountState),
      body: timeline.when(
        data: (posts) => RefreshIndicator(
          onRefresh: () => ref.refresh(homeTimelineProvider.future),
          child: ListView.separated(
            itemCount: posts.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => PostTile(post: posts[index]),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'タイムラインの読み込みに失敗しました\n$error',
              textAlign: TextAlign.center,
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
    final otherAccounts =
        accountState.accounts.where((a) => a.key != current?.key).toList();

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          UserAccountsDrawerHeader(
            accountName: Text(
              current?.user.displayName ?? current?.user.username ?? '',
            ),
            accountEmail: Text(
              '@${current?.user.username ?? ""}@${current?.key.host ?? ""}',
            ),
            currentAccountPicture: CircleAvatar(
              backgroundImage: current?.user.avatarUrl != null
                  ? NetworkImage(current!.user.avatarUrl!)
                  : null,
              child: current?.user.avatarUrl == null
                  ? Text(
                      (current?.user.username ?? '?')[0].toUpperCase(),
                      style: const TextStyle(fontSize: 24),
                    )
                  : null,
            ),
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
                leading: CircleAvatar(
                  radius: 16,
                  backgroundImage: account.user.avatarUrl != null
                      ? NetworkImage(account.user.avatarUrl!)
                      : null,
                  child: account.user.avatarUrl == null
                      ? Text(account.user.username[0].toUpperCase())
                      : null,
                ),
                title: Text(
                  account.user.displayName ?? account.user.username,
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
            const Divider(),
          ],
          ListTile(
            leading: const Icon(Icons.person_add),
            title: const Text('アカウントを追加'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/server');
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
        ],
      ),
    );
  }
}
