import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/announcement_provider.dart';
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

  test('⚠⚠ 同じサーバーの全アカウントを引き、同じお知らせは 1 件に束ねる', () async {
    final first = _Adapter();
    final second = _Adapter();
    when(
      () => first.getAnnouncements(),
    ).thenAnswer((_) async => [_announcement('a', 1)]);
    when(
      () => second.getAnnouncements(),
    ).thenAnswer((_) async => [_announcement('a', 1)]);

    final state = await load([
      _account('me', 'one.example', first),
      _account('sub', 'one.example', second),
    ]);

    expect(state.items.single.announcement.id, 'a');
    expect(state.items.single.accounts.map((a) => a.key.username), [
      'me',
      'sub',
    ]);
    verify(() => second.getAnnouncements()).called(1);
  });

  test('⚠⚠ 2 つ目のアカウント宛てのお知らせ（Misskey）も出す', () async {
    final first = _Adapter();
    final second = _Adapter();
    when(
      () => first.getAnnouncements(),
    ).thenAnswer((_) async => [_announcement('all', 1)]);
    when(() => second.getAnnouncements()).thenAnswer(
      (_) async => [_announcement('all', 1), _announcement('mine', 2)],
    );

    final state = await load([
      _account('me', 'one.example', first),
      _account('sub', 'one.example', second),
    ]);

    final mine = state.items.singleWhere((i) => i.announcement.id == 'mine');
    expect(mine.accounts.map((a) => a.key.username), ['sub']);
    expect(state.items, hasLength(2));
  });

  test('⚠⚠ どれか 1 つのアカウントで未読なら未読にする', () async {
    final first = _Adapter();
    final second = _Adapter();
    when(
      () => first.getAnnouncements(),
    ).thenAnswer((_) async => [_announcement('a', 1, read: true)]);
    when(
      () => second.getAnnouncements(),
    ).thenAnswer((_) async => [_announcement('a', 1)]);

    final state = await load([
      _account('me', 'one.example', first),
      _account('sub', 'one.example', second),
    ]);

    final item = state.items.single;
    expect(item.announcement.read, isFalse);
    expect(item.unreadAccounts.map((a) => a.key.username), ['sub']);
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

  test('⚠ 0 件のサーバーと落ちたサーバーだけなら、エラーにせず空を出す', () async {
    final empty = _Adapter();
    final down = _Adapter();
    when(() => empty.getAnnouncements()).thenAnswer((_) async => []);
    when(() => down.getAnnouncements()).thenThrow(StateError('boom'));

    final state = await load([
      _account('a', 'empty.example', empty),
      _account('b', 'down.example', down),
    ]);

    expect(state.items, isEmpty);
    expect(state.failedHosts, ['down.example']);
  });

  test('⚠⚠ 既読はまだ既読でないアカウントへ送る', () async {
    final first = _Adapter();
    final second = _Adapter();
    final already = _Adapter();
    when(() => first.dismissAnnouncement('a')).thenAnswer((_) async {});
    when(() => second.dismissAnnouncement('a')).thenAnswer((_) async {});

    final failures = await dismissUnifiedAnnouncement(
      UnifiedAnnouncement(
        host: 'one.example',
        announcement: _announcement('a', 1),
        accounts: [
          _account('me', 'one.example', first),
          _account('sub', 'one.example', second),
          _account('read', 'one.example', already),
        ],
        unreadAccounts: [
          _account('me', 'one.example', first),
          _account('sub', 'one.example', second),
        ],
      ),
    );

    expect(failures, isEmpty);
    verify(() => first.dismissAnnouncement('a')).called(1);
    verify(() => second.dismissAnnouncement('a')).called(1);
    verifyNever(() => already.dismissAnnouncement(any()));
  });

  test('⚠ 既読の失敗は、失敗したアカウントで返す（計装のホストを取り違えない）', () async {
    final ok = _Adapter();
    final down = _Adapter();
    when(() => ok.dismissAnnouncement('a')).thenAnswer((_) async {});
    when(() => down.dismissAnnouncement('a')).thenThrow(StateError('boom'));
    final okAccount = _account('me', 'one.example', ok);
    final downAccount = _account('sub', 'one.example', down);

    final failures = await dismissUnifiedAnnouncement(
      UnifiedAnnouncement(
        host: 'one.example',
        announcement: _announcement('a', 1),
        accounts: [okAccount, downAccount],
        unreadAccounts: [okAccount, downAccount],
      ),
    );

    expect(failures.single.account, same(downAccount));
    verify(() => ok.dismissAnnouncement('a')).called(1);
  });

  test('⚠ 1 アカウントの画面で既読にしたら、すべてのお知らせも取り直す', () async {
    final adapter = _Adapter();
    when(
      () => adapter.getAnnouncements(),
    ).thenAnswer((_) async => [_announcement('a', 1)]);
    when(() => adapter.dismissAnnouncement('a')).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _AccountNotifier([_account('me', 'one.example', adapter)]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(unifiedAnnouncementProvider, (_, _) {});
    container.listen(announcementProvider, (_, _) {});
    await container.read(unifiedAnnouncementProvider.future);
    await container.read(announcementProvider.future);
    clearInteractions(adapter);

    await container.read(announcementProvider.notifier).dismiss('a');
    await container.read(unifiedAnnouncementProvider.future);

    verify(() => adapter.getAnnouncements()).called(1);
  });
}
