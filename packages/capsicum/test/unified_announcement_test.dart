import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/unified_announcement_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1347: すべてのアカウントのお知らせ。
class _Adapter extends Mock
    implements DecentralizedBackendAdapter, AnnouncementSupport {}

class _NoAnnouncementAdapter extends Mock
    implements DecentralizedBackendAdapter {}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

Account _account(
  String name,
  String host,
  DecentralizedBackendAdapter adapter,
) => Account(
  key: AccountKey(type: BackendType.mastodon, host: host, username: name),
  adapter: adapter,
  user: User(id: name, username: name),
  userSecret: const UserSecret(accessToken: 'token'),
);

Announcement _announcement(String id, int day, {bool read = false}) =>
    Announcement(
      id: id,
      content: id,
      publishedAt: DateTime(2026, 1, day),
      read: read,
    );

void main() {
  Future<UnifiedAnnouncementState> load(List<Account> accounts) async {
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(() => _AccountNotifier(accounts)),
      ],
    );
    addTearDown(container.dispose);
    return container.read(unifiedAnnouncementProvider.future);
  }

  test('⚠ 同じサーバーは 1 回だけ引き、同じお知らせを 2 回出さない', () async {
    final first = _Adapter();
    final second = _Adapter();
    when(
      () => first.getAnnouncements(),
    ).thenAnswer((_) async => [_announcement('a', 1)]);

    final state = await load([
      _account('me', 'one.example', first),
      _account('sub', 'one.example', second),
    ]);

    expect(state.items.single.announcement.id, 'a');
    expect(state.items.single.accounts, hasLength(2));
    verifyNever(() => second.getAnnouncements());
  });

  test('未読を先に、その中は新しい順に並べる', () async {
    final one = _Adapter();
    final two = _Adapter();
    when(() => one.getAnnouncements()).thenAnswer(
      (_) async => [
        _announcement('old', 1),
        _announcement('read', 9, read: true),
      ],
    );
    when(
      () => two.getAnnouncements(),
    ).thenAnswer((_) async => [_announcement('new', 5)]);

    final state = await load([
      _account('a', 'one.example', one),
      _account('b', 'two.example', two),
    ]);

    expect(state.items.map((i) => i.announcement.id), ['new', 'old', 'read']);
  });

  test('⚠ 1 つのサーバーが落ちても、取れた分は出す', () async {
    final ok = _Adapter();
    final down = _Adapter();
    when(
      () => ok.getAnnouncements(),
    ).thenAnswer((_) async => [_announcement('a', 1)]);
    when(() => down.getAnnouncements()).thenThrow(StateError('boom'));

    final state = await load([
      _account('a', 'ok.example', ok),
      _account('b', 'down.example', down),
    ]);

    expect(state.items, hasLength(1));
    expect(state.failedHosts, ['down.example']);
  });

  test('全部落ちたらエラーにする（「お知らせはありません」と言わない）', () async {
    final down = _Adapter();
    when(() => down.getAnnouncements()).thenThrow(StateError('boom'));

    await expectLater(
      load([_account('a', 'down.example', down)]),
      throwsA(isA<StateError>()),
    );
  });

  test('お知らせに対応しないサーバーは数えない', () {
    final byHost = announcementAccountsByHost([
      _account('a', 'plain.example', _NoAnnouncementAdapter()),
    ]);

    expect(byHost, isEmpty);
  });

  test('⚠⚠ 既読は同じサーバーの全アカウントへ送る', () async {
    final first = _Adapter();
    final second = _Adapter();
    when(() => first.dismissAnnouncement('a')).thenAnswer((_) async {});
    when(() => second.dismissAnnouncement('a')).thenAnswer((_) async {});

    await dismissUnifiedAnnouncement(
      UnifiedAnnouncement(
        host: 'one.example',
        announcement: _announcement('a', 1),
        accounts: [
          _account('me', 'one.example', first),
          _account('sub', 'one.example', second),
        ],
      ),
    );

    verify(() => first.dismissAnnouncement('a')).called(1);
    verify(() => second.dismissAnnouncement('a')).called(1);
  });
}
