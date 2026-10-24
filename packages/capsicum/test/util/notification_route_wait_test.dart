import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/util/notification_route_wait.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1332: 通知のタップから画面を開くまでの待ち。
///
/// 以前はフレームの数（3600）だけが上限で、描画が止まっている間は進まず、宛先の
/// アカウントがずっと後で戻った時点で開いていた画面を置き換えた。待っている間に
/// 別の通知をタップすると経路が 2 本並び、古いほうが新しいほうを上書きした。
void main() {
  group('notificationRouteExpired', () {
    test('フレームの数でも実時間でも、上限に達したら諦める', () {
      expect(
        notificationRouteExpired(attempt: 10, elapsed: Duration.zero),
        isFalse,
      );
      expect(
        notificationRouteExpired(
          attempt: notificationRouteMaxAttempts,
          elapsed: Duration.zero,
        ),
        isTrue,
      );
      expect(
        notificationRouteExpired(
          attempt: 10,
          elapsed: notificationRouteDeadline,
        ),
        isTrue,
        reason: '⚠⚠ 描画が止まっていてフレームが進まなくても切れる',
      );
    });
  });

  group('復旧待ち', () {
    test('上限までは待ち、過ぎたら今のアカウントで開く', () {
      expect(notificationRecoveryStillWaiting(Duration.zero), isTrue);
      expect(
        notificationRecoveryStillWaiting(notificationRecoveryWait),
        isFalse,
      );
    });

    test('⚠⚠ 背景の再試行の立ち上がり（2・5・15 秒）が収まり、全体の上限より短い', () {
      final firstThreeRetries = kOfflineRetryRampUp
          .take(3)
          .fold(Duration.zero, (a, b) => a + b);
      expect(notificationRecoveryWait, greaterThan(firstThreeRetries));
      expect(notificationRecoveryWait, lessThan(notificationRouteDeadline));
    });

    test('⚠ 待ち始めてから数える（タップからではない）', () async {
      final ticket = NotificationRouteTicket.issue();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // session の復元を待っていた時間は数えない。
      expect(ticket.recoveryElapsed(), Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        ticket.recoveryElapsed(),
        greaterThanOrEqualTo(const Duration(milliseconds: 20)),
      );
      expect(ticket.recoveryElapsed(), lessThan(ticket.elapsed));
    });
  });

  group('NotificationRouteTicket', () {
    test('⚠⚠ 新しいタップが来たら、前の経路は最新でなくなる', () {
      final first = NotificationRouteTicket.issue();
      expect(first.isCurrent, isTrue);
      final second = NotificationRouteTicket.issue();
      expect(first.isCurrent, isFalse);
      expect(second.isCurrent, isTrue);
    });
  });
}
