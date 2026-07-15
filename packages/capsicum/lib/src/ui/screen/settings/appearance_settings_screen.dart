import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../provider/account_manager_provider.dart';
import '../../../provider/preferences_provider.dart';
import '../../widget/section_header.dart';

class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  static const _themeModeLabels = {
    ThemeMode.system: 'システム設定に従う',
    ThemeMode.light: 'ライト',
    ThemeMode.dark: 'ダーク',
  };

  static const _avatarShapeLabels = {
    AvatarShape.auto: '自動',
    AvatarShape.circle: '丸',
    AvatarShape.squircle: '角',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final fontScale = ref.watch(fontScaleProvider);
    final emojiSize = ref.watch(emojiSizeProvider);
    final thumbnailScale = ref.watch(thumbnailScaleProvider);
    final darkVariant = ref.watch(darkSurfaceVariantProvider);
    final darkText = ref.watch(darkTextColorProvider);
    final avatarShape = ref.watch(avatarShapeProvider);
    final adapter = ref.watch(currentAdapterProvider);
    // 設定 UI は Misskey アカウントにのみ表示する (#372)。Mastodon にはアバター
    // 形状の概念が無く、丼系サーバーは角アイコン前提で運用されているため
    // 設定そのものが不要。
    final showAvatarShape = adapter is ReactionSupport;
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
          const SectionHeader('テーマ'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
          if (isDark) ...[
            const SectionHeader('ダークモードの色合い'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
          ],

          // Dark text color
          if (isDark) ...[
            const SectionHeader('ダークモードの文字色'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
          ],

          // Avatar shape (Misskey accounts only)
          if (showAvatarShape) ...[
            const SectionHeader('アカウントアイコンの形状'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<AvatarShape>(
                    showSelectedIcon: false,
                    segments: [
                      for (final entry in _avatarShapeLabels.entries)
                        ButtonSegment(
                          value: entry.key,
                          label: Text(entry.value),
                        ),
                    ],
                    selected: {avatarShape},
                    onSelectionChanged: (selected) {
                      ref
                          .read(avatarShapeProvider.notifier)
                          .setShape(selected.first);
                    },
                  ),
                ],
              ),
            ),
          ],

          // Font scale
          const SectionHeader('文字サイズ'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
          const SectionHeader('カスタム絵文字サイズ'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
          const SectionHeader('サムネイルサイズ'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
