import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/announcement_provider.dart';
import '../../provider/unified_announcement_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../util/op_error.dart';
import '../widget/announcement_tile.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';
import '../widget/server_badge.dart';

/// すべてのアカウントのお知らせ (#1347)。デッキのカラムの中身。
class UnifiedAnnouncementView extends ConsumerWidget {
  const UnifiedAnnouncementView({super.key});

  Future<void> _dismiss(
    BuildContext context,
    WidgetRef ref,
    UnifiedAnnouncement item,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    final account = ref.read(currentAccountProvider);
    try {
      await dismissUnifiedAnnouncement(item);
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'announcement.op',
        operation: 'unified_dismiss',
        error: e,
        stackTrace: st,
        account: account,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('既読にできませんでした\n${summarizeOpError(e)}')),
      );
    }
    // ⚠ 一部のアカウントだけ成功した回も、サーバーの状態に揃える。未読の数を
    // 持っている現在のアカウントの一覧も取り直す。
    container.invalidate(unifiedAnnouncementProvider);
    unawaited(container.read(announcementProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcements = ref.watch(unifiedAnnouncementProvider);
    final theme = Theme.of(context);
    return BottomSafeArea(
      child: announcements.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => RetryErrorView(
          message: 'お知らせの読み込みに失敗しました\n${summarizeOpError(e)}',
          isRetrying: announcements.isLoading,
          onRetry: () => ref.invalidate(unifiedAnnouncementProvider),
        ),
        data: (state) => RefreshIndicator(
          onRefresh: () => ref.refresh(unifiedAnnouncementProvider.future),
          child: ListView(
            children: [
              if (state.failedHosts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '取得できなかったサーバー: ${state.failedHosts.join(" / ")}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (state.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('お知らせはありません')),
                ),
              for (final item in state.items) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      ServerFavicon(host: item.host),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          item.host,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                ),
                AnnouncementTile(
                  announcement: item.announcement,
                  host: item.host,
                  showReactions: false,
                  onDismiss: item.announcement.read
                      ? null
                      : () => _dismiss(context, ref, item),
                ),
                const Divider(height: 1),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
