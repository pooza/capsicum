import 'package:capsicum/src/service/delivered_push_cleaner.dart';
import 'package:capsicum/src/service/notification_dedup_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockDedupChannel extends Mock implements NotificationDedupChannel {}

void main() {
  late _MockDedupChannel channel;
  late DeliveredPushCleaner cleaner;

  setUpAll(() {
    registerFallbackValue(<String>[]);
  });

  setUp(() {
    channel = _MockDedupChannel();
    when(() => channel.removeDelivered(any())).thenAnswer((_) async {});
    cleaner = DeliveredPushCleaner(channel, supportedOverride: true);
  });

  tearDown(() => cleaner.dispose());

  group('DeliveredPushCleaner.sweep', () {
    test('既出キーと一致する stamped 通知だけを削除する', () async {
      when(() => channel.getDeliveredRemotes()).thenAnswer(
        (_) async => const [
          DeliveredRemoteNotification(
            identifier: 'apns-1',
            account: 'pooza@mstdn.b-shock.org',
            stampedId: 'n100',
          ),
          DeliveredRemoteNotification(
            identifier: 'apns-2',
            account: 'pooza@mstdn.b-shock.org',
            stampedId: 'n999', // WebSocket 側が未表示の通知
          ),
        ],
      );
      cleaner.recordEmitted('pooza@mstdn.b-shock.org|n100');

      await cleaner.sweep();

      verify(() => channel.removeDelivered(['apns-1'])).called(1);
    });

    test('既出キーが無ければ native を呼ばない', () async {
      await cleaner.sweep();
      verifyNever(() => channel.getDeliveredRemotes());
      verifyNever(() => channel.removeDelivered(any()));
    });

    test('body の無い通知 (announcement #477) は削除対象外', () async {
      when(() => channel.getDeliveredRemotes()).thenAnswer(
        (_) async => const [
          DeliveredRemoteNotification(
            identifier: 'apns-3',
            account: 'pooza@mstdn.b-shock.org',
            // body / encoding / stampedId なし
          ),
        ],
      );
      cleaner.recordEmitted('pooza@mstdn.b-shock.org|n100');

      await cleaner.sweep();

      verifyNever(() => channel.removeDelivered(any()));
    });

    test('アカウントが違えば同じ ID でも削除しない', () async {
      when(() => channel.getDeliveredRemotes()).thenAnswer(
        (_) async => const [
          DeliveredRemoteNotification(
            identifier: 'apns-4',
            account: 'other@example.com',
            stampedId: 'n100',
          ),
        ],
      );
      cleaner.recordEmitted('pooza@mstdn.b-shock.org|n100');

      await cleaner.sweep();

      verifyNever(() => channel.removeDelivered(any()));
    });

    test(
      'macOS 以外 (supportedOverride=false) では recordEmitted が no-op',
      () async {
        final disabled = DeliveredPushCleaner(
          channel,
          supportedOverride: false,
        );
        addTearDown(disabled.dispose);
        disabled.recordEmitted('pooza@mstdn.b-shock.org|n100');

        await disabled.sweep();

        verifyNever(() => channel.getDeliveredRemotes());
      },
    );
  });
}
