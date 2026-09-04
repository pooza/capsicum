import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account.dart';
import '../service/sentry_op_failure.dart';
import '../util/conversion_skip_report.dart';
import 'account_manager_provider.dart';
import 'is_cat_provider.dart';

/// A notification paired with the account it belongs to.
class UnifiedNotification {
  final Account account;
  final Notification notification;

  const UnifiedNotification({
    required this.account,
    required this.notification,
  });
}

class UnifiedNotificationState {
  final List<UnifiedNotification> items;
  final List<Account> failedAccounts;

  /// まだ取得中のアカウント (#862 A/B)。逐次描画中に「@user@host を待っています」
  /// を表示するために保持する。全件 settle すると空になる。
  final List<Account> pendingAccounts;

  /// 対象アカウント総数（取得状況「M 件中 N 件」の分母）。
  final int totalAccounts;

  const UnifiedNotificationState({
    this.items = const [],
    this.failedAccounts = const [],
    this.pendingAccounts = const [],
    this.totalAccounts = 0,
  });

  /// 全アカウントの取得が完了したか（成功・失敗を問わず settle 済み）。
  bool get isComplete => pendingAccounts.isEmpty;

  /// settle 済みのアカウント数（成功 + 失敗）。
  int get settledCount => totalAccounts - pendingAccounts.length;
}

/// Fetches the first page of notifications from every logged-in account in
/// parallel and merges them into a single chronological list. Per-account
/// marker state is left untouched — tapping an item should switch to the
/// owning account and open the existing single-account views.
class UnifiedNotificationNotifier
    extends AutoDisposeAsyncNotifier<UnifiedNotificationState> {
  static const _pageSize = 20;

  @override
  Future<UnifiedNotificationState> build() async {
    final accounts = ref.watch(accountManagerProvider).accounts;
    final supported = accounts
        .where((a) => a.adapter is NotificationSupport)
        .toList();
    if (supported.isEmpty) return const UnifiedNotificationState();

    // 逐次描画 (#862 A)。従来は Future.wait のバリアで全件 settle まで 1 件も
    // 描画されず、遅いサーバー 1 台に全体が人質に取られていた。ここでは各
    // アカウントを並列に投げつつ、返ってきた順に state を差し替える。build()
    // 自体は「全件 pending・items 空」の初期状態で即座に完了させ、画面を
    // スピナー固定にしない。取得状況（settled / pending / failed）は state に
    // 載せて画面上部に表示する (#862 B)。
    var disposed = false;
    ref.onDispose(() => disposed = true);

    final items = <UnifiedNotification>[];
    final failed = <Account>[];
    final pending = List<Account>.of(supported);

    for (final account in supported) {
      // fire-and-forget: 各 fetch の完了ごとに state を更新する。build() の
      // 戻り値（初期 state）が確定した後の tick で走るため、順次差し込まれる。
      _fetchFor(account).then((result) {
        if (disposed) return;
        pending.remove(result.account);
        if (result.error != null) {
          failed.add(result.account);
        } else {
          for (final n in result.notifications) {
            items.add(
              UnifiedNotification(account: result.account, notification: n),
            );
          }
          // 追加のたびに全体を時系列（新しい順）に整列し直す。
          items.sort(
            (a, b) =>
                b.notification.createdAt.compareTo(a.notification.createdAt),
          );
        }
        // 共有リストはミューテートし続けるため、state には都度コピーを載せる。
        state = AsyncData(
          UnifiedNotificationState(
            items: List.of(items),
            failedAccounts: List.of(failed),
            pendingAccounts: List.of(pending),
            totalAccounts: supported.length,
          ),
        );
      });
    }

    return UnifiedNotificationState(
      pendingAccounts: List.of(supported),
      totalAccounts: supported.length,
    );
  }

  Future<_FetchResult> _fetchFor(Account account) async {
    try {
      final response = await (account.adapter as NotificationSupport)
          .getNotifications(query: const TimelineQuery(limit: _pageSize));
      reportSkippedNotifications(
        response.skippedPosts,
        source: 'unified_notification',
      );
      final enricher = IsCatEnricher.forAccount(account);
      // ⚠ **猫耳のために通知一覧の表示を止めない (#1080)。**エンリッチは
      // モロヘイヤの `/account/is_cat` を叩き、キャッシュに無い acct を
      // その場でリモートへ取りに行く。到達不能なサーバーのアカウントからの
      // 通知が 1 件混ざっているだけで、ここが分単位で返らなくなっていた。
      //
      // ⚠ **`timeout` は下の future を止めない。**解決はバックグラウンドで
      // 続き、結果はプロセス共有のキャッシュに載るので次の取得で効く。
      final notifications = await enricher
          .enrichNotifications(response.notifications)
          .timeout(kIsCatEnrichBudget, onTimeout: () => response.notifications);
      return _FetchResult(account: account, notifications: notifications);
    } catch (e, st) {
      // 失敗は上部バナーでユーザーには見えるが、サーバー側で「どの host が・
      // どんな例外で・どの頻度で」落ちているかの可視性が無かった（#862 でこの
      // 経路を書き換え済み・リリース前レビュー黄）。プリセット host 優先運用に
      // 乗せて観測する。
      reportOpFailure(
        tagKey: 'notification.unified',
        operation: 'fetch',
        error: e,
        stackTrace: st,
        account: account,
      );
      return _FetchResult(account: account, notifications: const [], error: e);
    }
  }
}

class _FetchResult {
  final Account account;
  final List<Notification> notifications;
  final Object? error;

  const _FetchResult({
    required this.account,
    required this.notifications,
    this.error,
  });
}

final unifiedNotificationProvider =
    AsyncNotifierProvider.autoDispose<
      UnifiedNotificationNotifier,
      UnifiedNotificationState
    >(UnifiedNotificationNotifier.new);
