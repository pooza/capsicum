import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/platform/notification_subsystem/notification_subsystem.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/platform_providers.dart';
import 'package:capsicum/src/service/desktop_notification_dispatcher.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #675 デスクトップ通知の全アカウント並列購読のロジック検証。
/// 購読の増減追従・アカウント横断 dedup・複数垢時の宛先表示を対象にする。
class _FakeAdapter extends Mock
    implements DecentralizedBackendAdapter, NotificationStreamSupport {}

class _MockUser extends Mock implements User {}

class _MockUserSecret extends Mock implements UserSecret {}

/// 全アカウントを並列購読するため、build を空状態で始めてテストから差し替える。
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

/// show() 呼び出しを記録するだけの NotificationSubsystem。
class _RecordingSubsystem implements NotificationSubsystem {
  final List<({String title, String body, String? payload})> shown = [];

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
    shown.add((title: title, body: body, payload: payload));
  }
}

({Account account, StreamController<Notification> controller}) _makeAccount(
  String username,
  String host,
) {
  final controller = StreamController<Notification>.broadcast();
  final adapter = _FakeAdapter();
  when(adapter.streamNotifications).thenAnswer((_) => controller.stream);
  final account = Account(
    key: AccountKey(type: BackendType.mastodon, host: host, username: username),
    adapter: adapter,
    user: _MockUser(),
    userSecret: _MockUserSecret(),
  );
  return (account: account, controller: controller);
}

Notification _mention(String id, {User? user}) => Notification(
  id: id,
  type: NotificationType.mention,
  createdAt: DateTime(2026, 1, 1),
  user: user,
);

/// listener 発火とストリーム配信のためにマイクロタスクを 1 巡させる。
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _RecordingSubsystem subsystem;
  late _TestAccountNotifier notifier;
  late ProviderContainer container;

  setUp(() {
    subsystem = _RecordingSubsystem();
    container = ProviderContainer(
      overrides: [
        notificationSubsystemProvider.overrideWithValue(subsystem),
        accountManagerProvider.overrideWith(_TestAccountNotifier.new),
      ],
    );
    notifier =
        container.read(accountManagerProvider.notifier) as _TestAccountNotifier;
    // dispatcher を alive にして start() の listen を張る。
    container.read(desktopNotificationDispatcherProvider);
  });

  tearDown(() => container.dispose());

  test('全ログインアカウントの通知ストリームを購読する', () async {
    final a = _makeAccount('alice', 'h1');
    final b = _makeAccount('bob', 'h2');
    notifier.setAccounts([a.account, b.account]);
    await _settle();

    a.controller.add(_mention('a1'));
    b.controller.add(_mention('b1'));
    await _settle();

    expect(subsystem.shown.length, 2);
  });

  test('後からログインしたアカウントも購読対象になる', () async {
    final a = _makeAccount('alice', 'h1');
    notifier.setAccounts([a.account]);
    await _settle();

    final b = _makeAccount('bob', 'h2');
    notifier.setAccounts([a.account, b.account]);
    await _settle();

    b.controller.add(_mention('b1'));
    await _settle();

    expect(subsystem.shown.length, 1);
  });

  test('ログアウトしたアカウントの購読は解除される', () async {
    final a = _makeAccount('alice', 'h1');
    final b = _makeAccount('bob', 'h2');
    notifier.setAccounts([a.account, b.account]);
    await _settle();

    // bob をログアウト。
    notifier.setAccounts([a.account]);
    await _settle();

    b.controller.add(_mention('b1'));
    await _settle();

    expect(subsystem.shown, isEmpty);
  });

  test('別アカウントで同じ notification.id でも両方表示する（横断 dedup の衝突回避）', () async {
    final a = _makeAccount('alice', 'h1');
    final b = _makeAccount('bob', 'h2');
    notifier.setAccounts([a.account, b.account]);
    await _settle();

    // 同一 id をそれぞれの垢のストリームに流す。
    a.controller.add(_mention('dup'));
    b.controller.add(_mention('dup'));
    await _settle();

    expect(subsystem.shown.length, 2);
  });

  test('同一アカウントの同一 id は 1 回だけ表示する', () async {
    final a = _makeAccount('alice', 'h1');
    notifier.setAccounts([a.account]);
    await _settle();

    a.controller
      ..add(_mention('same'))
      ..add(_mention('same'));
    await _settle();

    expect(subsystem.shown.length, 1);
  });

  test('複数垢のときは title に宛先ハンドルを添える', () async {
    final a = _makeAccount('alice', 'h1');
    final b = _makeAccount('bob', 'h2');
    notifier.setAccounts([a.account, b.account]);
    await _settle();

    final user = _MockUser();
    when(() => user.displayName).thenReturn('送信者');
    when(() => user.username).thenReturn('sender');
    b.controller.add(_mention('b1', user: user));
    await _settle();

    expect(subsystem.shown.single.title, contains('(@bob@h2)'));
  });

  test('単一垢のときは title に宛先を添えない', () async {
    final a = _makeAccount('alice', 'h1');
    notifier.setAccounts([a.account]);
    await _settle();

    final user = _MockUser();
    when(() => user.displayName).thenReturn('送信者');
    when(() => user.username).thenReturn('sender');
    a.controller.add(_mention('a1', user: user));
    await _settle();

    expect(subsystem.shown.single.title, isNot(contains('@alice@h1')));
  });

  test('payload に宛先アカウントを含める', () async {
    final a = _makeAccount('alice', 'h1');
    notifier.setAccounts([a.account]);
    await _settle();

    a.controller.add(_mention('a1'));
    await _settle();

    expect(subsystem.shown.single.payload, contains('mastodon://alice@h1'));
  });
}
