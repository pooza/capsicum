// #1377: ほかの人のクリップをお気に入りに入れる・お気に入りのクリップの一覧。
import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/clip_favorites_screen.dart';
import 'package:capsicum/src/ui/screen/clip_notes_screen.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        ClipSupport,
        ClipManagementSupport,
        ClipFavoriteSupport {}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._current);

  final Account _current;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_current], current: _current);
}

void main() {
  late _Adapter adapter;

  setUpAll(() => registerFallbackValue(const TimelineQuery()));

  setUp(() {
    adapter = _Adapter();
    when(() => adapter.getClips()).thenAnswer((_) async => const []);
    when(
      () => adapter.getClipNotes(any(), query: any(named: 'query')),
    ).thenAnswer((_) async => const []);
  });

  Account account() => Account(
    key: const AccountKey(
      type: BackendType.misskey,
      host: 'misskey.example',
      username: 'me',
    ),
    adapter: adapter,
    user: const User(id: 'me', username: 'me'),
    userSecret: const UserSecret(accessToken: 'token'),
  );

  Future<void> pump(WidgetTester tester, Widget home) async {
    final current = account();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(() => _AccountNotifier(current)),
        ],
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  final star = find.byKey(const ValueKey('clip-favorite'));

  group('クリップの画面の ☆', () {
    testWidgets('⚠⚠ ほかの人のクリップなら出し、押すとお気に入りに入れる', (tester) async {
      when(() => adapter.getClip('c1')).thenAnswer(
        (_) async => const NoteClip(
          id: 'c1',
          name: '名場面',
          userId: 'alice',
          isFavorited: false,
        ),
      );
      when(() => adapter.favoriteClip(any())).thenAnswer((_) async {});
      await pump(tester, const ClipNotesScreen(clipId: 'c1'));

      expect(star, findsOneWidget);
      expect(find.byIcon(Icons.star_border), findsOneWidget);

      await tester.tap(star);
      await tester.pumpAndSettle();

      verify(() => adapter.favoriteClip('c1')).called(1);
      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('お気に入り済みなら外す', (tester) async {
      when(() => adapter.getClip('c1')).thenAnswer(
        (_) async => const NoteClip(
          id: 'c1',
          name: '名場面',
          userId: 'alice',
          isFavorited: true,
        ),
      );
      when(() => adapter.unfavoriteClip(any())).thenAnswer((_) async {});
      await pump(tester, const ClipNotesScreen(clipId: 'c1'));

      await tester.tap(star);
      await tester.pumpAndSettle();

      verify(() => adapter.unfavoriteClip('c1')).called(1);
      expect(find.byIcon(Icons.star_border), findsOneWidget);
    });

    testWidgets('⚠ 持ち主が自分なら出さない（一覧に無くても）', (tester) async {
      when(() => adapter.getClip('c1')).thenAnswer(
        (_) async => const NoteClip(id: 'c1', name: '自分の', userId: 'me'),
      );
      await pump(tester, const ClipNotesScreen(clipId: 'c1'));

      expect(star, findsNothing);
    });

    testWidgets('失敗したら戻して知らせる', (tester) async {
      when(() => adapter.getClip('c1')).thenAnswer(
        (_) async => const NoteClip(
          id: 'c1',
          name: '名場面',
          userId: 'alice',
          isFavorited: false,
        ),
      );
      when(() => adapter.favoriteClip(any())).thenThrow(const ClipNotFound());
      await pump(tester, const ClipNotesScreen(clipId: 'c1'));

      await tester.tap(star);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.star_border), findsOneWidget);
      expect(find.text('このクリップはもう見られません'), findsOneWidget);
    });
  });

  group('お気に入りのクリップの一覧', () {
    testWidgets('誰のクリップかを添えて並べる', (tester) async {
      when(() => adapter.getFavoriteClips()).thenAnswer(
        (_) async => const [
          NoteClip(
            id: 'c1',
            name: '名場面',
            ownerName: 'アリス',
            description: '第 1 話',
          ),
        ],
      );
      await pump(tester, const ClipFavoritesScreen());

      expect(find.text('名場面'), findsOneWidget);
      expect(find.text('アリス · 第 1 話'), findsOneWidget);
    });

    testWidgets('0 件なら入れ方を案内する', (tester) async {
      when(() => adapter.getFavoriteClips()).thenAnswer((_) async => const []);
      await pump(tester, const ClipFavoritesScreen());

      expect(find.textContaining('お気に入りのクリップはありません'), findsOneWidget);
    });
  });
}
