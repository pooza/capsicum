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
    final emojiSize = ref.watch(emojiSizeProvider);
    final thumbnailScale = ref.watch(thumbnailScaleProvider);
    final darkVariant = ref.watch(darkSurfaceVariantProvider);
    final darkText = ref.watch(darkTextColorProvider);
    final isDark =
        themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);

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

          // Dark surface variant
          if (isDark)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ダークモードの色合い',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: DarkSurfaceVariant.values.map((v) {
                      final isSelected = v == darkVariant;
                      final color =
                          darkSurfaceColor(v) ??
                          Theme.of(context).colorScheme.surface;
                      return ChoiceChip(
                        label: Text(darkSurfaceLabel(v)),
                        selected: isSelected,
                        avatar: CircleAvatar(
                          backgroundColor: color,
                          radius: 10,
                          child: isSelected
                              ? const Icon(
                                  Icons.check,
                                  size: 12,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                        onSelected: (_) {
                          ref
                              .read(darkSurfaceVariantProvider.notifier)
                              .setVariant(v);
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),

          // Dark text color
          if (isDark)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ダークモードの文字色',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: DarkTextColor.values.map((v) {
                      final isSelected = v == darkText;
                      final color =
                          darkTextColor(v) ??
                          Theme.of(context).colorScheme.onSurface;
                      return ChoiceChip(
                        label: Text(darkTextColorLabel(v)),
                        selected: isSelected,
                        avatar: CircleAvatar(
                          backgroundColor: color,
                          radius: 10,
                          child: isSelected
                              ? Icon(
                                  Icons.check,
                                  size: 12,
                                  color: color.computeLuminance() > 0.5
                                      ? Colors.black
                                      : Colors.white,
                                )
                              : null,
                        ),
                        onSelected: (_) {
                          ref.read(darkTextColorProvider.notifier).setColor(v);
                        },
                      );
                    }).toList(),
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

          // Emoji size
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'カスタム絵文字サイズ',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Text('🙂', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: emojiSize,
                        min: minEmojiSize,
                        max: maxEmojiSize,
                        divisions:
                            ((maxEmojiSize - minEmojiSize) / emojiSizeStep)
                                .round(),
                        label: '${emojiSize.round()}px',
                        onChanged: (value) {
                          ref.read(emojiSizeProvider.notifier).setSize(value);
                        },
                      ),
                    ),
                    const Text('🙂', style: TextStyle(fontSize: 24)),
                  ],
                ),
                if (emojiSize != defaultEmojiSize)
                  Center(
                    child: TextButton(
                      onPressed: () {
                        ref
                            .read(emojiSizeProvider.notifier)
                            .setSize(defaultEmojiSize);
                      },
                      child: const Text('デフォルトに戻す'),
                    ),
                  ),
              ],
            ),
          ),

          // Thumbnail scale
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'サムネイルサイズ',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.photo_size_select_small, size: 16),
                    Expanded(
                      child: Slider(
                        value: thumbnailScale,
                        min: minThumbnailScale,
                        max: maxThumbnailScale,
                        divisions:
                            ((maxThumbnailScale - minThumbnailScale) /
                                    thumbnailScaleStep)
                                .round(),
                        label: '${(thumbnailScale * 100).round()}%',
                        onChanged: (value) {
                          ref
                              .read(thumbnailScaleProvider.notifier)
                              .setScale(value);
                        },
                      ),
                    ),
                    const Icon(Icons.photo_size_select_large, size: 24),
                  ],
                ),
                if (thumbnailScale != defaultThumbnailScale)
                  Center(
                    child: TextButton(
                      onPressed: () {
                        ref
                            .read(thumbnailScaleProvider.notifier)
                            .setScale(defaultThumbnailScale);
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
