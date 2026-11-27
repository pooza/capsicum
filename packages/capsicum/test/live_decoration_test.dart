// #1409: 実況のためにモロヘイヤが付けたデコを、デコの画面で示して外せるようにする。
import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/avatar_decoration_screen.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Adapter extends Mock
    implements DecentralizedBackendAdapter, AvatarDecorationSupport {}

class _Mulukhiya extends Mock implements MulukhiyaService {}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._current);

  final Account _current;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_current], current: _current);
}

const _live = AvatarDecorationOption(
  id: 'live-1',
  name: '実況中 ゴメちゃん',
  url: 'https://example.invalid/live.png',
);

const _other = AvatarDecorationOption(
  id: 'other',
  name: 'かぼちゃ',
  url: 'https://example.invalid/a.png',
);

void main() {
  group('応答の読み取り', () {
    test('実況中の応答を読む', () {
      final live = MulukhiyaLiveDecoration.fromJson({
        'live': true,
        'id': 'live-1',
        'name': '実況中 ゴメちゃん',
        'program': 'ダイの大冒険',
        'restore_at': '2026-11-22T10:47:00+09:00',
      });
      expect(live.live, isTrue);
      expect(live.restorable, isTrue);
      expect(live.program, 'ダイの大冒険');
      expect(live.restoreAt, DateTime.utc(2026, 11, 22, 1, 47));
    });

    test('⚠⚠ id が無ければ外せない（実況の前から同じデコを付けていた）', () {
      final live = MulukhiyaLiveDecoration.fromJson({'live': true});
      expect(live.live, isTrue);
      expect(live.restorable, isFalse);
    });

    test('実況中でなければ live だけ', () {
      final live = MulukhiyaLiveDecoration.fromJson({'live': false});
      expect(live.live, isFalse);
      expect(live.restorable, isFalse);
    });

    test('読めない時刻は null（帯の文面から外す）', () {
      final live = MulukhiyaLiveDecoration.fromJson({
        'live': true,
        'restore_at': 'not a date',
      });
      expect(live.restoreAt, isNull);
    });
  });

  group('帯の文面', () {
    test('名前・番組・時刻が揃っていれば全部出す', () {
      final text = liveDecorationBannerText(
        MulukhiyaLiveDecoration(
          live: true,
          id: 'x',
          name: '実況中 ゴメちゃん',
          program: 'ダイの大冒険',
          restoreAt: DateTime(2026, 11, 22, 10, 7),
        ),
      );
      expect(text, '「実況中 ゴメちゃん」は実況中のデコです（ダイの大冒険）。10:07ごろ、番組の終わりに外れます。');
    });

    test('分からないものは省く', () {
      expect(
        liveDecorationBannerText(const MulukhiyaLiveDecoration(live: true)),
        '実況中のデコが付いています。番組の終わりに外れます。',
      );
    });
  });

  group('デコの画面', () {
    late _Adapter adapter;
    late _Mulukhiya mulukhiya;

    Account account({List<AvatarDecoration> decorations = const []}) => Account(
      key: const AccountKey(
        type: BackendType.misskey,
        host: 'misskey.example',
        username: 'me',
      ),
      adapter: adapter,
      user: User(id: 'me', username: 'me', avatarDecorations: decorations),
      userSecret: const UserSecret(accessToken: 'token'),
      mulukhiya: mulukhiya,
    );

    setUp(() {
      adapter = _Adapter();
      mulukhiya = _Mulukhiya();
      when(
        () => adapter.getAvatarDecorationOptions(),
      ).thenAnswer((_) async => [_live, _other]);
      when(() => adapter.getAvatarDecorationLimit()).thenAnswer((_) async => 3);
    });

    Future<ProviderContainer> pump(WidgetTester tester, Account current) async {
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(() => _AccountNotifier(current)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AvatarDecorationScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    final banner = find.byKey(const ValueKey('live-decoration-banner'));
    final restore = find.byKey(const ValueKey('live-decoration-restore'));

    testWidgets('⚠⚠ 実況中なら帯を出し、外すデコの行にも示す', (tester) async {
      when(
        () =>
            mulukhiya.getLiveDecoration(accessToken: any(named: 'accessToken')),
      ).thenAnswer(
        (_) async => const MulukhiyaLiveDecoration(
          live: true,
          id: 'live-1',
          name: '実況中 ゴメちゃん',
        ),
      );
      await pump(
        tester,
        account(
          decorations: const [
            AvatarDecoration(id: 'live-1', url: 'https://example.invalid/l'),
          ],
        ),
      );

      expect(banner, findsOneWidget);
      expect(restore, findsOneWidget);
      expect(find.text('実況中（番組の終わりに外れます）'), findsOneWidget);
    });

    testWidgets('「いま外す」で外し、自分を引き直して帯を消す', (tester) async {
      var live = true;
      when(
        () =>
            mulukhiya.getLiveDecoration(accessToken: any(named: 'accessToken')),
      ).thenAnswer(
        (_) async => live
            ? const MulukhiyaLiveDecoration(live: true, id: 'live-1')
            : const MulukhiyaLiveDecoration(live: false),
      );
      when(
        () => mulukhiya.restoreLiveDecoration(
          accessToken: any(named: 'accessToken'),
        ),
      ).thenAnswer((_) async => live = false);
      when(
        () => adapter.getMyself(),
      ).thenAnswer((_) async => const User(id: 'me', username: 'me'));
      final container = await pump(
        tester,
        account(
          decorations: const [
            AvatarDecoration(id: 'live-1', url: 'https://example.invalid/l'),
          ],
        ),
      );

      await tester.tap(restore);
      await tester.pumpAndSettle();

      verify(
        () => mulukhiya.restoreLiveDecoration(accessToken: 'token'),
      ).called(1);
      expect(banner, findsNothing);
      expect(
        container.read(currentAccountProvider)!.user.avatarDecorations,
        isEmpty,
        reason: '引き直した自分をアカウントへ反映する',
      );
    });

    testWidgets('⚠ 外す相手が分からなければ、帯だけ出して「外す」は出さない', (tester) async {
      when(
        () =>
            mulukhiya.getLiveDecoration(accessToken: any(named: 'accessToken')),
      ).thenAnswer((_) async => const MulukhiyaLiveDecoration(live: true));
      await pump(tester, account());

      expect(banner, findsOneWidget);
      expect(restore, findsNothing);
    });

    testWidgets('⚠ 口が無い（404 で null）・読めないときは何も出さない', (tester) async {
      when(
        () =>
            mulukhiya.getLiveDecoration(accessToken: any(named: 'accessToken')),
      ).thenThrow(Exception('boom'));
      await pump(tester, account());

      expect(banner, findsNothing);
      expect(find.text('かぼちゃ'), findsOneWidget, reason: '画面そのものは使える');
    });
  });
}
