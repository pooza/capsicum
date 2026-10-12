import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/platform/notification_subsystem/notification_subsystem.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/platform_providers.dart';
import 'package:capsicum/src/service/desktop_notification_dispatcher.dart';
import 'package:capsicum/src/service/notification_dedup_channel.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1261: 回線が切れていた短い間に届いた通知を、つなぎ直したあと OS 通知として
/// 出す。⚠⚠ **上限つき**（2026-10-10 pooza）—— スリープ明けに数時間ぶんの
/// バナーをまとめて出さない。
class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        NotificationStreamSupport,
        NotificationSupport {}

class _MockUser extends Mock implements User {}

class _MockUserSecret extends Mock implements UserSecret {}

class _TestAccountNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() => const AccountManagerState();

  void setAccounts(List<Account> accounts) {
    state = AccountManagerState(
      accounts: accounts,
      current: accounts.isEmpty ? null : accounts.first,
    );
  }
}

class _FakeDedupChannel extends NotificationDedupChannel {
  @override
  void start() {}

  @override
  Future<void> addEmitted(String key) async {}
}

class _RecordingSubsystem implements NotificationSubsystem {
  final List<String?> shown = [];

  @override
  Future<void> initialize({void Function(String? payload)? onTap}) async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    NotificationCategory category = NotificationCategory.message,
  }) async {
    shown.add(payload);
  }
}

final _t0 = DateTime.utc(2026, 10, 12, 12);

Notification _mention(String id, DateTime at) =>
    Notification(id: id, type: NotificationType.mention, createdAt: at);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('selectMissedNotifications', () {
    test('切れたあとに届いたものだけを、古い順で返す', () {
      final missed = selectMissedNotifications(
        [
          _mention('new', _t0.add(const Duration(seconds: 40))),
          _mention('mid', _t0.add(const Duration(seconds: 20))),
          _mention('old', _t0.subtract(const Duration(minutes: 1))),
        ],
        disconnectedAt: _t0,
        now: _t0.add(const Duration(minutes: 1)),
      );
      expect(missed.map((n) => n.id), ['mid', 'new']);
    });

    test('⚠⚠ 多ければ新しいほうから 3 件まで（残りは通知の一覧に任せる）', () {
      final missed = selectMissedNotifications(
        [
          for (var i = 5; i >= 1; i--)
            _mention('n$i', _t0.add(Duration(seconds: i * 10))),
        ],
        disconnectedAt: _t0,
        now: _t0.add(const Duration(minutes: 2)),
      );
      expect(kMissedNotificationMaxCount, 3);
      expect(missed.map((n) => n.id), ['n3', 'n4', 'n5']);
    });

    test('⚠⚠ 長い切断（スリープ明け）では、直近 10 分より前のものは出さない', () {
      final now = _t0.add(const Duration(hours: 3));
      final missed = selectMissedNotifications(
        [
          _mention('recent', now.subtract(const Duration(minutes: 5))),
          _mention('stale', now.subtract(const Duration(minutes: 30))),
          _mention('ancient', _t0.add(const Duration(minutes: 1))),
        ],
        disconnectedAt: _t0,
        now: now,
      );
      expect(missed.map((n) => n.id), ['recent']);
    });

    test('時計のずれぶん、切れた時刻の少し前から拾う', () {
      final missed = selectMissedNotifications(
        [
          _mention('just_before', _t0.subtract(const Duration(seconds: 3))),
          _mention('well_before', _t0.subtract(const Duration(seconds: 30))),
        ],
        disconnectedAt: _t0,
        now: _t0.add(const Duration(seconds: 30)),
      );
      expect(missed.map((n) => n.id), ['just_before']);
    });

    test('切れていた間に何も届いていなければ空', () {
      expect(
        selectMissedNotifications(
          [_mention('old', _t0.subtract(const Duration(hours: 1)))],
          disconnectedAt: _t0,
          now: _t0.add(const Duration(seconds: 30)),
        ),
        isEmpty,
      );
    });
  });

  group('つなぎ直したあとの拾い直し', () {
    late _RecordingSubsystem subsystem;
    late ProviderContainer container;
    late _Adapter adapter;
    late StreamController<Notification> stream;
    late void Function(String event) connectionEvent;
    late DateTime clock;
    var fetches = 0;
    var fetched = <Notification>[];

    setUp(() async {
      subsystem = _RecordingSubsystem();
      adapter = _Adapter();
      stream = StreamController<Notification>.broadcast();
      clock = _t0;
      fetches = 0;
      fetched = [];
      when(
        () => adapter.streamNotifications(
          onParseError: any(named: 'onParseError'),
          onStreamError: any(named: 'onStreamError'),
          onReconnectExhausted: any(named: 'onReconnectExhausted'),
          onConnectionEvent: any(named: 'onConnectionEvent'),
        ),
      ).thenAnswer((invocation) {
        connectionEvent =
            invocation.namedArguments[#onConnectionEvent]
                as void Function(String);
        return stream.stream;
      });
      when(
        () => adapter.getNotifications(
          query: any(named: 'query'),
          filter: any(named: 'filter'),
        ),
      ).thenAnswer((_) async {
        fetches++;
        return NotificationResponse(
          notifications: fetched,
          rawCount: fetched.length,
        );
      });
      container = ProviderContainer(
        overrides: [
          notificationSubsystemProvider.overrideWithValue(subsystem),
          accountManagerProvider.overrideWith(_TestAccountNotifier.new),
          notificationDedupChannelProvider.overrideWithValue(
            _FakeDedupChannel(),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(desktopNotificationDispatcherProvider).now = () => clock;
      (container.read(accountManagerProvider.notifier) as _TestAccountNotifier)
          .setAccounts([
            Account(
              key: const AccountKey(
                type: BackendType.mastodon,
                host: 'mstdn.example',
                username: 'me',
              ),
              adapter: adapter,
              user: _MockUser(),
              userSecret: _MockUserSecret(),
            ),
          ]);
      await _settle();
    });

    test('⚠ 起動して最初の接続では拾い直さない（切れていた間が無い）', () async {
      connectionEvent('connected');
      await _settle();

      expect(fetches, 0);
      expect(subsystem.shown, isEmpty);
    });

    test('短い切断の間に届いた通知が、つなぎ直したあとに出る', () async {
      connectionEvent('connected');
      connectionEvent('disconnected');
      fetched = [_mention('m1', _t0.add(const Duration(seconds: 20)))];
      clock = _t0.add(const Duration(seconds: 40));

      connectionEvent('connected');
      await _settle();

      expect(fetches, 1);
      expect(subsystem.shown, hasLength(1));
      expect(subsystem.shown.single, contains('"notificationId":"m1"'));
    });

    test('⚠⚠ 同じ通知を 2 回出さない（接続からも流れてきた・もう一度切れた）', () async {
      connectionEvent('connected');
      final m1 = _mention('m1', _t0.add(const Duration(seconds: 20)));
      connectionEvent('disconnected');
      fetched = [m1];
      clock = _t0.add(const Duration(seconds: 40));
      connectionEvent('connected');
      await _settle();
      expect(subsystem.shown, hasLength(1));

      // つなぎ直した直後に、接続からも同じ通知が流れてくる。
      stream.add(m1);
      await _settle();
      expect(subsystem.shown, hasLength(1));

      // すぐにもう一度切れて、同じ通知が拾い直しの窓にまた入る。
      connectionEvent('disconnected');
      clock = _t0.add(const Duration(seconds: 50));
      connectionEvent('connected');
      await _settle();
      expect(fetches, 2);
      expect(subsystem.shown, hasLength(1));
    });

    test('⚠⚠ 無音で切れた回線では、検知するより前に届いた通知も拾う', () async {
      // 購読は 10 分前から。回線は 12:10:00 に無音で切れ、ping の応答切れで
      // 検知するのは 90 秒後。その間（切れて 30 秒後）に通知が届いている。
      connectionEvent('connected');
      clock = _t0.add(const Duration(minutes: 10, seconds: 90));
      connectionEvent('disconnected');
      fetched = [
        _mention('silent', _t0.add(const Duration(minutes: 10, seconds: 30))),
      ];
      clock = _t0.add(const Duration(minutes: 10, seconds: 100));

      connectionEvent('connected');
      await _settle();

      expect(
        subsystem.shown,
        hasLength(1),
        reason: '検知した時刻より前に届いているが、切れていた間の通知',
      );
    });

    test('⚠⚠ 起点は購読を始めた時刻より前へは下がらない（起動前の通知を出さない）', () async {
      // 起動して 20 秒で切断を検知。起動の 30 秒前に届いていた通知は出さない。
      connectionEvent('connected');
      clock = _t0.add(const Duration(seconds: 20));
      connectionEvent('disconnected');
      fetched = [
        _mention('before-launch', _t0.subtract(const Duration(seconds: 30))),
      ];
      clock = _t0.add(const Duration(seconds: 40));

      connectionEvent('connected');
      await _settle();

      expect(fetches, 1);
      expect(subsystem.shown, isEmpty);
    });

    test('⚠ つなぎ直しに失敗し続けても、基準は最初に切れた時刻のまま', () async {
      connectionEvent('connected');
      connectionEvent('disconnected');
      // 失敗するたびに disconnected が来る。ここで基準が後ろへずれると、
      // 最初の切断の直後に届いた通知を落とす。
      clock = _t0.add(const Duration(seconds: 30));
      connectionEvent('disconnected');
      fetched = [_mention('early', _t0.add(const Duration(seconds: 10)))];
      clock = _t0.add(const Duration(seconds: 50));

      connectionEvent('connected');
      await _settle();

      expect(subsystem.shown, hasLength(1));
    });

    test('⚠ 取得に失敗しても落ちない（通知の一覧には載っている）', () async {
      when(
        () => adapter.getNotifications(
          query: any(named: 'query'),
          filter: any(named: 'filter'),
        ),
      ).thenThrow(Exception('offline'));
      connectionEvent('connected');
      connectionEvent('disconnected');

      connectionEvent('connected');
      await _settle();

      expect(subsystem.shown, isEmpty);
    });
  });
}
