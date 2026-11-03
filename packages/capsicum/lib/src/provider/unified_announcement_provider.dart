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
    this.unreadAccounts = const [],
  });

  final String host;

  /// ⚠ [Announcement.read] は「[unreadAccounts] が空か」に付け直してある。
  final Announcement announcement;

  /// このお知らせが**実際に返ってきた**アカウント。⚠ Misskey はアカウント宛ての
  /// お知らせがあるので、同じサーバーでも全員が持っているとは限らない。
  final List<Account> accounts;

  /// [accounts] のうち、まだ既読を付けていないもの。⚠ 既読はアカウントごとに付く。
  final List<Account> unreadAccounts;
}

class UnifiedAnnouncementState {
  const UnifiedAnnouncementState({
    this.items = const [],
    this.failedHosts = const [],
  });

  final List<UnifiedAnnouncement> items;

  /// 取得できなかったサーバー。⚠ 全部が失敗でなければ、取れた分は出す。
  /// ⚠ 同じサーバーのアカウントが 1 つでも落ちたら載せる（そのアカウント宛ての
  /// お知らせが欠けている）。
  final List<String> failedHosts;
}

/// [accounts] をお知らせに対応するものだけに絞り、サーバーごとに束ねる。
Map<String, List<Account>> announcementAccountsByHost(List<Account> accounts) {
  final byHost = <String, List<Account>>{};
  for (final account in accounts) {
    if (account.adapter is! AnnouncementSupport) continue;
    byHost.putIfAbsent(account.key.host, () => []).add(account);
  }
  return byHost;
}

/// すべてのアカウントのお知らせ (#1347)。未読を先に出す。
///
/// ⚠⚠ **同じサーバーでも全アカウントを引く。**Misskey の `/api/announcements` は
/// 「全員宛て ＋ 自分宛て」を返し、既読もアカウントごとに付く（Mastodon も既読は
/// アカウントごと）。先頭の 1 つだけだと、2 つ目のアカウント宛てのお知らせが
/// 出ず、2 つ目だけ未読のものが既読に見える。(サーバー, ID) で 1 件に束ねる。
final unifiedAnnouncementProvider =
    FutureProvider.autoDispose<UnifiedAnnouncementState>((ref) async {
      final accounts = ref.watch(
        accountManagerProvider.select((state) => state.accounts),
      );
      final targets = announcementAccountsByHost(
        accounts,
      ).values.expand((e) => e).toList();

      final failures =
          <({Account account, Object error, StackTrace stackTrace})>[];
      // ⚠ 並列に引くが、束ねるのはアカウントの並び順で行う（返ってきた順にしない）。
      final results = await Future.wait(
        targets.map((account) async {
          try {
            return await (account.adapter as AnnouncementSupport)
                .getAnnouncements();
          } catch (e, st) {
            failures.add((account: account, error: e, stackTrace: st));
            return null;
          }
        }),
      );
      if (failures.isNotEmpty) {
        reportFanOutFailures(
          tagKey: 'announcement.list',
          operation: 'unified_fetch',
          failures: failures,
          totalAccounts: targets.length,
        );
      }
      // ⚠ 全部が落ちたときだけエラーにする。取れたサーバーが 0 件なだけなら
      // 「お知らせはありません」＋取れなかったサーバーを出す。
      if (failures.isNotEmpty && failures.length == targets.length) {
        Error.throwWithStackTrace(
          failures.first.error,
          failures.first.stackTrace,
        );
      }

      final merged =
          <
            (String, String),
            ({
              Announcement announcement,
              List<Account> accounts,
              List<Account> unread,
            })
          >{};
      for (var i = 0; i < targets.length; i++) {
        final account = targets[i];
        for (final a in results[i] ?? const <Announcement>[]) {
          final entry = merged.putIfAbsent(
            (account.key.host, a.id),
            () => (announcement: a, accounts: <Account>[], unread: <Account>[]),
          );
          entry.accounts.add(account);
          if (!a.read) entry.unread.add(account);
        }
      }
      final items = [
        for (final MapEntry(key: (host, _), :value) in merged.entries)
          UnifiedAnnouncement(
            host: host,
            // ⚠ どれか 1 つでも未読なら未読（既読を付ける口を出す）。
            announcement: value.announcement.copyWith(
              read: value.unread.isEmpty,
            ),
            accounts: value.accounts,
            unreadAccounts: value.unread,
          ),
      ];
      items.sort((a, b) {
        final read = (a.announcement.read ? 1 : 0).compareTo(
          b.announcement.read ? 1 : 0,
        );
        if (read != 0) return read;
        return b.announcement.publishedAt.compareTo(a.announcement.publishedAt);
      });
      final failedHosts =
          failures.map((f) => f.account.key.host).toSet().toList()..sort();
      return UnifiedAnnouncementState(items: items, failedHosts: failedHosts);
    });

/// 既読を付ける。⚠ まだ既読でない全アカウントへ送る（どれか 1 つだけだと、別の
/// アカウントへ切り替えたときに同じお知らせが未読で戻ってくる）。
///
/// 失敗したアカウントを返す（空なら全部成功）。⚠ 計装は失敗した**そのアカウント**の
/// ホストで付ける（画面の現在のアカウントではない）ので、呼び出し側へ返す。
Future<List<({Account account, Object error, StackTrace stackTrace})>>
dismissUnifiedAnnouncement(UnifiedAnnouncement item) async {
  final failures = <({Account account, Object error, StackTrace stackTrace})>[];
  await Future.wait(
    item.unreadAccounts.map((account) async {
      try {
        await (account.adapter as AnnouncementSupport).dismissAnnouncement(
          item.announcement.id,
        );
      } catch (e, st) {
        failures.add((account: account, error: e, stackTrace: st));
      }
    }),
  );
  return failures;
}

/// ルートの [ProviderContainer] (#1347)。
///
/// ⚠ 依存を持たない provider はルートに載るので、デッキのカラムのスコープ
/// （`deck_screen.dart` の `_containerFor`）から読んでもルートが返る。カラムの
/// スコープの `announcementProvider` はそのカラムのアカウントのもので、未読の
/// バッジを持つ現在のアカウントのものではない。
final rootProviderContainerProvider = Provider<ProviderContainer>(
  (ref) => ref.container,
);
