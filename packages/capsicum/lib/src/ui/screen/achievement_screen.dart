import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/achievement_provider.dart';

class AchievementScreen extends ConsumerWidget {
  final String userId;
  final String? displayName;

  const AchievementScreen({super.key, required this.userId, this.displayName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final achievements = ref.watch(achievementProvider(userId));

    return Scaffold(
      appBar: AppBar(
        title: Text(displayName != null ? '$displayName の実績' : '実績'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: achievements.when(
        data: (items) {
          if (items.isEmpty) {
            return const Center(child: Text('実績はまだありません'));
          }
          // Sort by unlockedAt descending (newest first).
          final sorted = [...items]
            ..sort((a, b) => b.unlockedAt.compareTo(a.unlockedAt));
          return RefreshIndicator(
            onRefresh: () => ref.refresh(achievementProvider(userId).future),
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.85,
              ),
              itemCount: sorted.length,
              itemBuilder: (context, index) =>
                  _AchievementTile(achievement: sorted[index]),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('実績の読み込みに失敗しました\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(achievementProvider(userId)),
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AchievementTile extends StatelessWidget {
  final Achievement achievement;

  const _AchievementTile({required this.achievement});

  @override
  Widget build(BuildContext context) {
    final meta = achievementCatalog[achievement.name];
    final theme = Theme.of(context);
    final frameColor = _frameColor(meta?.frame, theme);
    final d = achievement.unlockedAt;
    final dateText = '${d.year}/${d.month}/${d.day}';

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: frameColor, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(context, meta, dateText),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                meta?.emoji ?? '\u{2753}',
                style: const TextStyle(fontSize: 32),
              ),
              const SizedBox(height: 6),
              Text(
                meta?.label ?? achievement.name,
                style: theme.textTheme.labelSmall,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context, AchievementMeta? meta, String date) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                meta?.emoji ?? '\u{2753}',
                style: const TextStyle(fontSize: 48),
              ),
              const SizedBox(height: 12),
              Text(
                meta?.label ?? achievement.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                _frameLabel(meta?.frame),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _frameColor(meta?.frame, Theme.of(context)),
                ),
              ),
              const SizedBox(height: 8),
              Text(date, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  static Color _frameColor(AchievementFrame? frame, ThemeData theme) {
    return switch (frame) {
      AchievementFrame.bronze => const Color(0xFFCD7F32),
      AchievementFrame.silver => const Color(0xFFC0C0C0),
      AchievementFrame.gold => const Color(0xFFFFD700),
      AchievementFrame.platinum => const Color(0xFFE5E4E2),
      null => theme.colorScheme.outlineVariant,
    };
  }

  static String _frameLabel(AchievementFrame? frame) {
    return switch (frame) {
      AchievementFrame.bronze => 'Bronze',
      AchievementFrame.silver => 'Silver',
      AchievementFrame.gold => 'Gold',
      AchievementFrame.platinum => 'Platinum',
      null => '',
    };
  }
}
