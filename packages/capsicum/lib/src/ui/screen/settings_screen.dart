import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/preferences_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontScale = ref.watch(fontScaleProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          _FontScaleTile(fontScale: fontScale, ref: ref),
        ],
      ),
    );
  }
}

class _FontScaleTile extends StatelessWidget {
  final double fontScale;
  final WidgetRef ref;

  const _FontScaleTile({required this.fontScale, required this.ref});

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                      ((maxFontScale - minFontScale) / fontScaleStep).round(),
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
    );
  }
}
