import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontScale = ref.watch(fontScaleProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          _sectionHeader(context, 'アカウント別'),
          _AccountLabel(ref: ref),
          _ThemeColorTile(ref: ref),
          _TabOrderTile(ref: ref),
          _sectionHeader(context, '共通'),
          _FontScaleTile(fontScale: fontScale, ref: ref),
        ],
      ),
    );
  }
}

class _AccountLabel extends StatelessWidget {
  final WidgetRef ref;

  const _AccountLabel({required this.ref});

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    if (account == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        '@${account.key.username}@${account.key.host}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

Widget _sectionHeader(BuildContext context, String title) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('テーマカラー', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
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
                        .read(accountThemeColorProvider(storageKey).notifier)
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
    );
  }
}

class _TabOrderTile extends StatelessWidget {
  final WidgetRef ref;

  const _TabOrderTile({required this.ref});

  static const _mastodonLabels = {
    TimelineType.home: 'ホーム',
    TimelineType.local: 'ローカル',
    TimelineType.federated: '連合',
  };

  static const _misskeyLabels = {
    TimelineType.home: 'ホーム',
    TimelineType.local: 'ローカル',
    TimelineType.social: 'ソーシャル',
    TimelineType.federated: 'グローバル',
  };

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    if (account == null) return const SizedBox.shrink();

    final adapter = ref.watch(currentAdapterProvider);
    final supported =
        adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final isMisskey = adapter is ReactionSupport;
    final labels = isMisskey ? _misskeyLabels : _mastodonLabels;

    // モロヘイヤのデフォルトハッシュタグがあればローカルタブ名に反映
    final localLabel = ref.watch(localTimelineNameProvider);

    final storageKey = account.key.toStorageKey();
    final order = ref.watch(tabOrderProvider(storageKey));
    // サーバーがサポートするタイムラインのみ表示
    final visibleOrder = order.where(supported.contains).toList();
    final isCustom = order != defaultTabOrder;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('タブの順序', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: visibleOrder.length,
            onReorder: (oldIndex, newIndex) {
              final newOrder = List<TimelineType>.from(visibleOrder);
              if (newIndex > oldIndex) newIndex--;
              final item = newOrder.removeAt(oldIndex);
              newOrder.insert(newIndex, item);
              ref
                  .read(tabOrderProvider(storageKey).notifier)
                  .setOrder(newOrder);
            },
            itemBuilder: (context, index) {
              final type = visibleOrder[index];
              final label = type == TimelineType.local
                  ? localLabel
                  : (labels[type] ?? type.name);
              return ListTile(
                key: ValueKey(type),
                dense: true,
                leading: const Icon(Icons.drag_handle),
                title: Text(label),
              );
            },
          ),
          if (isCustom)
            Center(
              child: TextButton(
                onPressed: () {
                  ref.read(tabOrderProvider(storageKey).notifier).reset();
                },
                child: const Text('デフォルトに戻す'),
              ),
            ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'リストのタブはこれらの後に表示されます',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (adapter is ListSupport)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: TextButton.icon(
                icon: const Icon(Icons.edit_note, size: 18),
                label: const Text('リスト管理'),
                onPressed: () => context.push('/lists/manage'),
              ),
            ),
        ],
      ),
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
                  divisions: ((maxFontScale - minFontScale) / fontScaleStep)
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
    );
  }
}
