import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../provider/account_manager_provider.dart';
import '../../../provider/platform_providers.dart';
import '../../../provider/preferences_provider.dart';
import '../../util/spotify_link.dart';
import '../../widget/section_header.dart';
import '../../widget/tab_management_sheet.dart';

class AccountSettingsScreen extends ConsumerWidget {
  const AccountSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    if (account == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(
        title: const Text('アカウント設定'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '@${account.key.username}@${account.key.host}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          _ThemeColorTile(ref: ref),
          _BackgroundImageTile(ref: ref),
          _TabOrderTile(ref: ref),
          const _SpotifyLinkTile(),
        ],
      ),
    );
  }
}

class _ThemeColorTile extends StatelessWidget {
  final WidgetRef ref;

  const _ThemeColorTile({required this.ref});

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    if (account == null) return const SizedBox.shrink();

    final storageKey = account.key.toStorageKey();
    final currentColor = ref.watch(accountThemeColorProvider(storageKey));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('テーマカラー'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final color in themeColorPresets)
                    _ColorCircle(
                      color: color,
                      selected: currentColor?.toARGB32() == color.toARGB32(),
                      onTap: () {
                        ref
                            .read(
                              accountThemeColorProvider(storageKey).notifier,
                            )
                            .setColor(color);
                      },
                    ),
                ],
              ),
              if (currentColor != null)
                Center(
                  child: TextButton(
                    onPressed: () {
                      ref
                          .read(accountThemeColorProvider(storageKey).notifier)
                          .setColor(null);
                    },
                    child: const Text('デフォルトに戻す'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabOrderTile extends StatelessWidget {
  final WidgetRef ref;

  const _TabOrderTile({required this.ref});

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    if (account == null) return const SizedBox.shrink();

    final adapter = ref.watch(currentAdapterProvider);
    final storageKey = account.key.toStorageKey();

    return ListTile(
      leading: const Icon(Icons.tune),
      title: const Text('タブ管理'),
      subtitle: const Text('タブの並び替え・表示切替・ハッシュタグ'),
      onTap: () {
        final supported =
            adapter?.capabilities.supportedTimelines ??
            {TimelineType.home, TimelineType.local, TimelineType.federated};
        final isMastodon = !supported.contains(TimelineType.social);
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => TabManagementSheet(
            storageKey: storageKey,
            isMastodon: isMastodon,
          ),
        );
      },
    );
  }
}

/// Spotify 連携セクション (#570)。サーバーが Spotify user OAuth を提供
/// (`spotify_enabled`) するアカウントでのみ表示し、連携状態 (`spotify_linked`)
/// に応じて連携 / 解除ボタンを出す。連携 / 解除後は `redetectMulukhiya` で
/// フラグを更新し、compose のナウプレ挿入ボタンの出し分けに即時追従させる。
class _SpotifyLinkTile extends ConsumerStatefulWidget {
  const _SpotifyLinkTile();

  @override
  ConsumerState<_SpotifyLinkTile> createState() => _SpotifyLinkTileState();
}

class _SpotifyLinkTileState extends ConsumerState<_SpotifyLinkTile> {
  bool _busy = false;

  Future<void> _link() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final linked = await runSpotifyLinkFlow(context, ref);
      if (linked) {
        await ref.read(accountManagerProvider.notifier).redetectMulukhiya();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlink() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final unlinked = await runSpotifyUnlinkFlow(context, ref);
      if (unlinked) {
        await ref.read(accountManagerProvider.notifier).redetectMulukhiya();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mulukhiya = ref.watch(currentMulukhiyaProvider);
    if (mulukhiya == null || !mulukhiya.spotifyEnabled) {
      return const SizedBox.shrink();
    }
    final linked = mulukhiya.spotifyLinked;
    return ListTile(
      leading: const Icon(Icons.music_note),
      title: const Text('Spotify 連携'),
      subtitle: Text(
        linked
            ? '連携済み。投稿フォームの「ナウプレを挿入」で再生中の曲を貼れます。'
            : '連携すると、再生中の曲を投稿フォームに挿入できます。',
      ),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (linked
                ? TextButton(onPressed: _unlink, child: const Text('連携解除'))
                : FilledButton(onPressed: _link, child: const Text('連携する'))),
    );
  }
}

class _BackgroundImageTile extends StatelessWidget {
  final WidgetRef ref;

  const _BackgroundImageTile({required this.ref});

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    if (account == null) return const SizedBox.shrink();

    final storageKey = account.key.toStorageKey();
    final imagePath = ref.watch(backgroundImageProvider(storageKey));
    final opacity = ref.watch(backgroundOpacityProvider(storageKey));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('背景画像'),
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
                    onPressed: () async {
                      final file = await ref
                          .read(mediaPickerProvider)
                          .pickImage();
                      if (file != null) {
                        await ref
                            .read(backgroundImageProvider(storageKey).notifier)
                            .setImage(file.path);
                      }
                    },
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

class _ColorCircle extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _ColorCircle({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected ? Border.all(color: Colors.white, width: 3) : null,
          boxShadow: selected
              ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4)]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 18)
            : null,
      ),
    );
  }
}
