import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/clip_edit_screen.dart';
import 'package:capsicum/src/ui/util/provider_scope_carrier.dart';
import 'package:capsicum/src/ui/widget/clip_add_sheet.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

/// v2.11 のリリース前レビュー（🔴・Codex P1）: デッキで別アカウントのカラムの
/// 投稿から「クリップに追加 → 新しいクリップ」を選ぶと、**ルートで選ばれている
/// アカウント**にクリップができていた。
///
/// シートは別のルートに乗るので中の `context` はルートのスコープになり、
/// `/clips/edit` もスコープを持ち込まない。シートを開いた側のスコープで包み、
/// `extraWithProviderScope` で運んで、ルーターの builder が包み直す。
///
/// ⚠ ルートは `router.dart` の `/clips/edit` と同じ形に組んである（アプリの
/// ルーター全体は認証やシェルを抱えていて、ここでは組めない）。push の側は
/// `provider_scope_push_guard_test` が見ている。
class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        ClipSupport,
        ClipManagementSupport {}

final _post = Post(
  id: 'n1',
  postedAt: DateTime.utc(2026, 11, 11),
  author: const User(id: 'u1', username: 'alice'),
);

const _created = NoteClip(id: 'new', name: '実況');

void main() {
  setUpAll(() {
    registerFallbackValue(const ClipDraft(name: ''));
  });

  late _Adapter rootAdapter;
  late _Adapter columnAdapter;

  _Adapter stub() {
    final a = _Adapter();
    when(() => a.getClips()).thenAnswer((_) async => const []);
    when(
      () => a.getPublicClipIdsContaining(any()),
    ).thenAnswer((_) async => const {});
    when(() => a.createClip(any())).thenAnswer((_) async => _created);
    when(() => a.addNoteToClip(any(), any())).thenAnswer((_) async {});
    return a;
  }

  setUp(() {
    rootAdapter = stub();
    columnAdapter = stub();
  });

  testWidgets('⚠⚠ カラムのアカウントでクリップを作り、そこへ投稿を入れる', (tester) async {
    final root = ProviderContainer(
      overrides: [
        currentAdapterProvider.overrideWithValue(rootAdapter),
        currentAccountProvider.overrideWithValue(null),
      ],
    );
    addTearDown(root.dispose);
    // デッキ画面がカラムごとに作るのと同じ、ルートを親にした入れ子のコンテナ。
    final column = ProviderContainer(
      parent: root,
      overrides: [currentAdapterProvider.overrideWithValue(columnAdapter)],
    );
    addTearDown(column.dispose);

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: carryProviderScope(
              column,
              Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => showAddToClipSheet(context, ref, _post),
                  child: const Text('クリップに追加'),
                ),
              ),
            ),
          ),
        ),
        // `router.dart` の `/clips/edit` と同じ形。
        GoRoute(
          path: '/clips/edit',
          builder: (context, state) {
            final extra = state.extra;
            final clip = extra is Map ? extra['clip'] : null;
            return withExtraProviderScope(
              extra,
              ClipEditScreen(clip: clip is NoteClip ? clip : null),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: root,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('クリップに追加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新しいクリップ'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名前'), '実況');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    verify(() => columnAdapter.createClip(any())).called(1);
    verifyNever(() => rootAdapter.createClip(any()));
    verify(() => columnAdapter.addNoteToClip('new', 'n1')).called(1);
  });
}
