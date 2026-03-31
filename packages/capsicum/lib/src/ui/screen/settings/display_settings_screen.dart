import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../provider/preferences_provider.dart';

class DisplaySettingsScreen extends ConsumerWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hideLivecure = ref.watch(hideLivecureProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('表示'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('#実況 タグの投稿を非表示'),
            subtitle: const Text('実況中の投稿をタイムラインから隠します'),
            value: hideLivecure,
            onChanged: (_) =>
                ref.read(hideLivecureProvider.notifier).toggle(),
          ),
        ],
      ),
    );
  }
}
