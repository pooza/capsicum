import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../provider/preferences_provider.dart';

class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  static const _themeModeLabels = {
    ThemeMode.system: 'システム設定に従う',
    ThemeMode.light: 'ライト',
    ThemeMode.dark: 'ダーク',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final fontScale = ref.watch(fontScaleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('テーマ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          // Theme mode
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('テーマ', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<ThemeMode>(
                  segments: [
                    for (final entry in _themeModeLabels.entries)
                      ButtonSegment(value: entry.key, label: Text(entry.value)),
                  ],
                  selected: {themeMode},
                  onSelectionChanged: (selected) {
                    ref
                        .read(themeModeProvider.notifier)
                        .setMode(selected.first);
                  },
                ),
              ],
            ),
          ),

          // Font scale
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('文字サイズ', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Text('A', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: fontScale,
                        min: minFontScale,
                        max: maxFontScale,
                        divisions:
                            ((maxFontScale - minFontScale) / fontScaleStep)
                                .round(),
                        label: '${(fontScale * 100).round()}%',
                        onChanged: (value) {
                          ref.read(fontScaleProvider.notifier).setScale(value);
                        },
                      ),
                    ),
                    const Text('A', style: TextStyle(fontSize: 20)),
                  ],
                ),
                Center(
                  child: Text(
                    'プレビュー: これは ${(fontScale * 100).round()}% の文字サイズです',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                if (fontScale != defaultFontScale)
                  Center(
                    child: TextButton(
                      onPressed: () {
                        ref
                            .read(fontScaleProvider.notifier)
                            .setScale(defaultFontScale);
                      },
                      child: const Text('デフォルトに戻す'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
