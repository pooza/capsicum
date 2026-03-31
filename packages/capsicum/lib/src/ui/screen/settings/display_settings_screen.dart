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
    final previewCardMode = ref.watch(previewCardModeProvider);

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
          ListTile(
            title: const Text('プレビューカード（OGP）'),
            subtitle: Text(_previewCardModeLabel(previewCardMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPreviewCardModeDialog(context, ref),
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

  String _previewCardModeLabel(PreviewCardMode mode) {
    return switch (mode) {
      PreviewCardMode.show => '表示',
      PreviewCardMode.blur => '画像をぼかす',
      PreviewCardMode.hide => '非表示',
    };
  }

  void _showPreviewCardModeDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('プレビューカード（OGP）'),
        children: [
          RadioGroup<PreviewCardMode>(
            groupValue: ref.watch(previewCardModeProvider),
            onChanged: (value) {
              if (value != null) {
                ref.read(previewCardModeProvider.notifier).setMode(value);
                Navigator.pop(context);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in PreviewCardMode.values)
                  RadioListTile<PreviewCardMode>(
                    title: Text(_previewCardModeLabel(mode)),
                    value: mode,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
