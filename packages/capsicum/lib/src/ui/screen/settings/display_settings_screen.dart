import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../provider/preferences_provider.dart';

class DisplaySettingsScreen extends ConsumerWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hideLivecure = ref.watch(hideLivecureProvider);
    final absoluteTime = ref.watch(absoluteTimeProvider);
    final blurAllImages = ref.watch(blurAllImagesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('表示'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('絶対時間で表示'),
            subtitle: const Text('投稿日時を「3分前」ではなく「2026-03-26 12:34」形式で表示します'),
            value: absoluteTime,
            onChanged: (_) =>
                ref.read(absoluteTimeProvider.notifier).toggle(),
          ),
          SwitchListTile(
            title: const Text('すべての画像をぼかす'),
            subtitle: const Text('NSFW フラグに関係なくすべての画像をぼかし表示にします。タップで個別に表示できます'),
            value: blurAllImages,
            onChanged: (_) =>
                ref.read(blurAllImagesProvider.notifier).toggle(),
          ),
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
