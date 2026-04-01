import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('アカウント設定'),
            subtitle: account != null
                ? Text('@${account.key.username}@${account.key.host}')
                : null,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/account'),
          ),
          ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('テーマ'),
            subtitle: const Text('配色・文字サイズ'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/appearance'),
          ),
          ListTile(
            leading: const Icon(Icons.visibility),
            title: const Text('表示'),
            subtitle: const Text('タイムライン表示の設定'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/display'),
          ),
        ],
      ),
    );
  }
}
