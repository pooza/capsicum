import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/announcement_provider.dart';
import '../widget/announcement_tile.dart';

final _infoBotUserProvider = FutureProvider.autoDispose<User?>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  final acct = ref.watch(currentMulukhiyaProvider)?.infoBotAcct;
  if (adapter == null || acct == null) return null;

  final normalized = acct.startsWith('@') ? acct.substring(1) : acct;
  final parts = normalized.split('@');
  if (parts.length != 2) return null;

  return adapter.getUser(parts[0], parts[1]);
});

/// Standalone screen with AppBar.
class AnnouncementScreen extends ConsumerWidget {
  const AnnouncementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('お知らせ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: const AnnouncementView(),
    );
  }
}

/// Reusable body widget for embedding as a home-screen tab.
class AnnouncementView extends ConsumerWidget {
  const AnnouncementView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcements = ref.watch(announcementProvider);
    final mulukhiya = ref.watch(currentMulukhiyaProvider);
    final infoBotAcct = mulukhiya?.infoBotAcct;

    return announcements.when(
      data: (state) => state.announcements.isEmpty && infoBotAcct == null
          ? const Center(child: Text('お知らせはありません'))
          : RefreshIndicator(
              onRefresh: () => ref.refresh(announcementProvider.future),
              child: ListView.separated(
                itemCount:
                    state.announcements.length +
                    (infoBotAcct != null ? 1 : 0),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (infoBotAcct != null) {
                    if (index == 0) {
                      return _InfoBotBanner(
                        acct: infoBotAcct,
                        onTap: () => _openInfoBotProfile(context, ref),
                        avatarUrl: ref
                            .watch(_infoBotUserProvider)
                            .valueOrNull
                            ?.avatarUrl,
                      );
                    }
                    index -= 1;
                  }
                  final announcement = state.announcements[index];
                  return AnnouncementTile(
                    announcement: announcement,
                    host: ref.read(currentAccountProvider)?.key.host,
                    onDismiss: announcement.read
                        ? null
                        : () => ref
                              .read(announcementProvider.notifier)
                              .dismiss(announcement.id),
                  );
                },
              ),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('お知らせの読み込みに失敗しました\n$error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(announcementProvider),
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openInfoBotProfile(BuildContext context, WidgetRef ref) async {
    final user = ref.read(_infoBotUserProvider).valueOrNull;
    if (user != null && context.mounted) {
      context.push('/profile', extra: user);
    }
  }
}

class _InfoBotBanner extends StatelessWidget {
  final String acct;
  final VoidCallback onTap;
  final String? avatarUrl;

  const _InfoBotBanner({
    required this.acct,
    required this.onTap,
    this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            if (avatarUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  avatarUrl!,
                  width: 20,
                  height: 20,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.smart_toy,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                ),
              )
            else
              Icon(Icons.smart_toy, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'お知らせボット (${acct.startsWith('@') ? acct : '@$acct'})',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
