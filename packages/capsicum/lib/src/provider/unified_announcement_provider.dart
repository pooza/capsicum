import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account.dart';
import '../service/sentry_op_failure.dart';
import 'account_manager_provider.dart';

/// お知らせとサーバーの組 (#1347)。
class UnifiedAnnouncement {
  const UnifiedAnnouncement({
    required this.host,
    required this.announcement,
    required this.accounts,
  });

  final String host;
  final Announcement announcement;

  /// このサーバーのアカウント。⚠ 既読はアカウントごとに付くので、全員へ送る。
  final List<Account> accounts;
}

class UnifiedAnnouncementState {
  const UnifiedAnnouncementState({
    this.items = const [],
    this.failedHosts = const [],
  });

  final List<UnifiedAnnouncement> items;

  /// 取得できなかったサーバー。⚠ 全部が失敗でなければ、取れた分は出す。
  final List<String> failedHosts;
}

/// [accounts] をお知らせに対応するものだけに絞り、サーバーごとに束ねる。
///
/// ⚠ お知らせはサーバー単位なので、同じサーバーのアカウントが複数あっても中身は
/// 同じになる。引くのは先頭の 1 つだけで、同じお知らせを 2 回出さない。
Map<String, List<Account>> announcementAccountsByHost(List<Account> accounts) {
  final byHost = <String, List<Account>>{};
  for (final account in accounts) {
    if (account.adapter is! AnnouncementSupport) continue;
    byHost.putIfAbsent(account.key.host, () => []).add(account);
  }
  return byHost;
}

/// すべてのアカウントのお知らせ (#1347)。未読を先に出す。
final unifiedAnnouncementProvider =
    FutureProvider.autoDispose<UnifiedAnnouncementState>((ref) async {
      final accounts = ref.watch(
        accountManagerProvider.select((state) => state.accounts),
      );
      final byHost = announcementAccountsByHost(accounts);

      final items = <UnifiedAnnouncement>[];
      final failedHosts = <String>[];
      final failures =
          <({Account account, Object error, StackTrace stackTrace})>[];
      await Future.wait(
        byHost.entries.map((entry) async {
          final first = entry.value.first;
          try {
            final announcements = await (first.adapter as AnnouncementSupport)
                .getAnnouncements();
            items.addAll(
              announcements.map(
                (a) => UnifiedAnnouncement(
                  host: entry.key,
                  announcement: a,
                  accounts: entry.value,
                ),
              ),
            );
          } catch (e, st) {
            failedHosts.add(entry.key);
            failures.add((account: first, error: e, stackTrace: st));
          }
        }),
      );
      if (failures.isNotEmpty) {
        reportFanOutFailures(
          tagKey: 'announcement.list',
          operation: 'unified_fetch',
          failures: failures,
          totalAccounts: byHost.length,
        );
      }
      if (items.isEmpty && failures.isNotEmpty) {
        Error.throwWithStackTrace(
          failures.first.error,
          failures.first.stackTrace,
        );
      }
      // ⚠ 並列に積むので、返ってきた順にならないよう整える。
      items.sort((a, b) {
        final read = (a.announcement.read ? 1 : 0).compareTo(
          b.announcement.read ? 1 : 0,
        );
        if (read != 0) return read;
        return b.announcement.publishedAt.compareTo(a.announcement.publishedAt);
      });
      failedHosts.sort();
      return UnifiedAnnouncementState(items: items, failedHosts: failedHosts);
    });

/// 既読を付ける。⚠ 同じサーバーの全アカウントへ送る（どれか 1 つだけだと、別の
/// アカウントへ切り替えたときに同じお知らせが未読で戻ってくる）。
Future<void> dismissUnifiedAnnouncement(UnifiedAnnouncement item) async {
  await Future.wait(
    item.accounts.map(
      (account) => (account.adapter as AnnouncementSupport).dismissAnnouncement(
        item.announcement.id,
      ),
    ),
  );
}
