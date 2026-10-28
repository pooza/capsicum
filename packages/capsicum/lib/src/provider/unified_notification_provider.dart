import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account.dart';
import '../service/sentry_op_failure.dart';
import '../util/announcement_notifications.dart';
import '../util/conversion_skip_report.dart';
import '../util/notification_filter.dart';
import 'account_manager_provider.dart';
import 'is_cat_provider.dart';
import 'preferences_provider.dart';

/// 「すべての通知」が 1 アカウントから引く件数。
///
/// ⚠ 既読を返す前の確かめ（[UnifiedNotificationReadSaver]）も同じ件数で引く。
/// Misskey のグループ化した取得は「この件数を引いてから束ねる」ので、件数が
/// 違うと先頭のグループの id が変わり、一致しなくなる。
const kUnifiedNotificationPageSize = 20;

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

  /// アカウント（保存用のキー）ごとの、絞り込みで落とす前の一番新しい通知
  /// (#1291 のリリース前レビュー)。既読はこの通知まで返す —— 先頭をフィルターで
  /// 伏せていると、見えている先頭はその下になり、伏せた通知が未読で残る。
  final Map<String, String> rawNewestIds;

  const UnifiedNotificationState({
    this.items = const [],
    this.failedAccounts = const [],
    this.pendingAccounts = const [],
    this.totalAccounts = 0,
    this.rawNewestIds = const {},
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
  @override
  Future<UnifiedNotificationState> build() async {
    // 絞り込みとグループ化 (#1042 / #1048)。⚠ **watch する** — 設定を変えたら
    // 全アカウントぶん取り直す。`_fetchFor` は fire-and-forget で走るので、
    // build 内で値を確定させてから渡す（`ref.read` を fetch 側に置くと、
    // dispose 済みの ref を読む経路ができる）。
    final filter = NotificationQuery(
      excludeTypes: ref.watch(notificationExcludedTypesProvider),
      grouped: ref.watch(notificationGroupingProvider),
    );
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
    final rawNewestIds = <String, String>{};
    final pending = List<Account>.of(supported);
    // 失敗の報告は、全員が返ってからまとめて行う (#1246)。⚠ 返ってきた順に
    // 1 件ずつ送ると、回線が切れた 1 回でアカウントの数だけ error が飛ぶ。
    final failures =
        <({Account account, Object error, StackTrace stackTrace})>[];

    for (final account in supported) {
      // fire-and-forget: 各 fetch の完了ごとに state を更新する。build() の
      // 戻り値（初期 state）が確定した後の tick で走るため、順次差し込まれる。
      _fetchFor(account, filter).then((result) {
        if (disposed) return;
        pending.remove(result.account);
        if (result.error case final error?) {
          failed.add(result.account);
          failures.add((
            account: result.account,
            error: error,
            stackTrace: result.stackTrace ?? StackTrace.empty,
          ));
        } else {
          if (result.rawNewestId case final id?) {
            rawNewestIds[result.account.key.toStorageKey()] = id;
          }
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
            rawNewestIds: Map.of(rawNewestIds),
          ),
        );
        if (pending.isEmpty) {
          reportFanOutFailures(
            // ⚠ 一覧の取得は `<領域>.list` (#1117-E / #1144)。
            tagKey: 'notification.list',
            operation: 'unified_fetch',
            failures: failures,
            totalAccounts: supported.length,
          );
        }
      });
    }

    return UnifiedNotificationState(
      pendingAccounts: List.of(supported),
      totalAccounts: supported.length,
    );
  }

  Future<_FetchResult> _fetchFor(
    Account account,
    NotificationQuery filter,
  ) async {
    try {
      // お知らせも並べる (#1308)。⚠ 通知と並行して取り、取れなくても空が返る。
      final announcements = announcementsForNotifications(
        account,
        excludeTypes: filter.excludeTypes,
      );
      final response = await (account.adapter as NotificationSupport)
          .getNotifications(
            query: const TimelineQuery(limit: kUnifiedNotificationPageSize),
            filter: filter,
          );
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
      // ⚠ **待ち上限は enricher の中で掛かる (#1083-C)。**ここに `.timeout` を
      // 書き足さないこと。
      final notifications = await enricher.enrichNotifications(
        dropFilteredNotifications(response.notifications),
      );
      // ⚠ 1 ページ目しか取らないので、続きがあるならそのページより古いお知らせは
      // 出さない（読み込んでいない通知より下に並ぶ・`mergeAnnouncements`）。
      final withAnnouncements = mergeAnnouncements(
        notifications,
        await announcements,
        hasMore:
            response.hasMore ??
            response.rawCount >= kUnifiedNotificationPageSize,
      );
      return _FetchResult(
        account: account,
        notifications: withAnnouncements.merged,
        rawNewestId: response.notifications.firstOrNull?.id,
      );
    } catch (e, st) {
      // 失敗は上部バナーでユーザーには見えるが、サーバー側で「どの host が・
      // どんな例外で・どの頻度で」落ちているかの可視性が無かった（#862 でこの
      // 経路を書き換え済み・リリース前レビュー黄）。プリセット host 優先運用に
      // 乗せて観測する。⚠ **報告は呼ぶ側が、全員ぶんをまとめて行う** (#1246)。
      return _FetchResult(
        account: account,
        notifications: const [],
        error: e,
        stackTrace: st,
      );
    }
  }
}

class _FetchResult {
  final Account account;
  final List<Notification> notifications;
  final Object? error;
  final StackTrace? stackTrace;
  final String? rawNewestId;

  const _FetchResult({
    required this.account,
    required this.notifications,
    this.error,
    this.stackTrace,
    this.rawNewestId,
  });
}

final unifiedNotificationProvider =
    AsyncNotifierProvider.autoDispose<
      UnifiedNotificationNotifier,
      UnifiedNotificationState
    >(UnifiedNotificationNotifier.new);
