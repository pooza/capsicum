import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/announcement_provider.dart';
import '../../provider/server_config_provider.dart';
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
    // ⚠ カラムは現在のアカウント以外のスコープに居ることがある (#1099)。未読の
    // バッジを持つのはルートの現在のアカウントの一覧なので、ルートで取り直す。
    final root = ref.read(rootProviderContainerProvider);
    final failures = await dismissUnifiedAnnouncement(item);
    // ⚠ 計装は失敗したアカウントで付ける（現在のアカウントのホストを付けない）。
    for (final f in failures) {
      reportOpFailure(
        tagKey: 'announcement.op',
        operation: 'unified_dismiss',
        error: f.error,
        stackTrace: f.stackTrace,
        account: f.account,
      );
    }
    if (failures.isNotEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '既読にできませんでした\n${summarizeOpError(failures.first.error)}',
          ),
        ),
      );
    }
    // ⚠ 一部のアカウントだけ成功した回も、サーバーの状態に揃える。
    root.invalidate(unifiedAnnouncementProvider);
    // ⚠ 生きていなければ起こさない（#915 → #919 と同じ）。次に開いたときの
    // build() が最新を取る。
    if (root.exists(announcementProvider)) {
      unawaited(root.read(announcementProvider.notifier).refresh());
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcements = ref.watch(unifiedAnnouncementProvider);
    final themeColors = ref.watch(hostThemeColorProvider);
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
                    '取得できなかったサーバー: '
                    '${state.failedHosts.map(serverDisplayName).join(" / ")}',
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
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    // どのサーバーのお知らせか。すべての通知のティッカーと揃える。
                    child: ServerBadge.fromHost(
                      item.host,
                      themeColors: themeColors,
                      showIcon: true,
                    ),
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
