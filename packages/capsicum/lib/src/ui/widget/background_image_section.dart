import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/platform_providers.dart';
import '../../provider/preferences_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../util/op_error.dart';
import 'section_header.dart';

/// 背景画像の設定欄。アカウント設定（アカウントごと）と表示設定（デッキ・#1174）
/// が使う。[storageKey] が保存先を決める。
class BackgroundImageSection extends ConsumerWidget {
  const BackgroundImageSection({
    super.key,
    required this.storageKey,
    this.title = '背景画像',
  });

  final String storageKey;
  final String title;

  /// ⚠ 選択やコピーの失敗を黙らせない (#1353)。押しても何も起きないように見える。
  Future<void> _pickImage(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ref.read(mediaPickerProvider).pickImage();
      if (file == null) return;
      await ref
          .read(backgroundImageProvider(storageKey).notifier)
          .setImage(file.path);
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'background_image.op',
        operation: 'pick',
        error: e,
        stackTrace: st,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('背景画像を設定できませんでした\n${summarizeOpError(e)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imagePath = ref.watch(backgroundImageProvider(storageKey));
    final opacity = ref.watch(backgroundOpacityProvider(storageKey));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (imagePath != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(imagePath),
                    height: 120,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(
                      height: 120,
                      child: Center(child: Icon(Icons.broken_image)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.opacity, size: 16),
                    Expanded(
                      child: Slider(
                        value: opacity,
                        min: minBackgroundOpacity,
                        max: maxBackgroundOpacity,
                        divisions:
                            ((maxBackgroundOpacity - minBackgroundOpacity) /
                                    backgroundOpacityStep)
                                .round(),
                        label: '${(opacity * 100).round()}%',
                        onChanged: (value) {
                          ref
                              .read(
                                backgroundOpacityProvider(storageKey).notifier,
                              )
                              .setOpacity(value);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () => _pickImage(context, ref),
                    icon: const Icon(Icons.image, size: 16),
                    label: Text(imagePath != null ? '変更' : '画像を選択'),
                  ),
                  if (imagePath != null) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        ref
                            .read(backgroundImageProvider(storageKey).notifier)
                            .clear();
                      },
                      child: const Text('解除'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
