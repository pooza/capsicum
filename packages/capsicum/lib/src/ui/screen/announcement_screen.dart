import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/announcement_provider.dart';
import '../widget/announcement_tile.dart';

class AnnouncementScreen extends ConsumerWidget {
  const AnnouncementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcements = ref.watch(announcementProvider);
    final mulukhiya = ref.watch(currentMulukhiyaProvider);
    final infoBotAcct = mulukhiya?.infoBotAcct;

    return Scaffold(
      appBar: AppBar(
        title: const Text('お知らせ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: announcements.when(
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
      ),
    );
  }

  Future<void> _openInfoBotProfile(BuildContext context, WidgetRef ref) async {
    final adapter = ref.read(currentAdapterProvider);
    final acct = ref.read(currentMulukhiyaProvider)?.infoBotAcct;
    if (adapter == null || acct == null) return;

    // acct may be "@username@host" or "username@host"
    final normalized = acct.startsWith('@') ? acct.substring(1) : acct;
    final parts = normalized.split('@');
    if (parts.length != 2) return;

    final user = await adapter.getUser(parts[0], parts[1]);
    if (user != null && context.mounted) {
      context.push('/profile', extra: user);
    }
  }
}

class _InfoBotBanner extends StatelessWidget {
  final String acct;
  final VoidCallback onTap;

  const _InfoBotBanner({required this.acct, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
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
