import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/service/annict_draft_store.dart';
import 'package:capsicum/src/ui/util/annict_draft_auto_save.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1382: Annict の感想・記録の本文と評価を、作品 / 話数ごと・アカウント別に
/// 自動保存する。
const _me = 'mastodon://me@mstdn.example';
const _other = 'mastodon://other@mstdn.example';

class _Adapter extends Mock implements DecentralizedBackendAdapter {}

/// 読み込みを [gate] が完了するまで返さない保存の仕組み。
class _SlowStore extends AnnictDraftStore {
  _SlowStore(this.gate, this.draft)
    : super(accountKey: _me, kind: AnnictDraftKind.record, id: 42);

  final Completer<void> gate;
  final AnnictDraft draft;

  @override
  Future<AnnictDraft?> load() async {
    await gate.future;
    return draft;
  }
}

/// mixin を使う最小の画面。
class _Screen extends ConsumerStatefulWidget {
  const _Screen({this.store});

  /// 非 null なら保存の仕組みをこれに差し替える。
  final AnnictDraftStore? store;

  @override
  ConsumerState<_Screen> createState() => _ScreenState();
}

class _ScreenState extends ConsumerState<_Screen> with AnnictDraftAutoSave {
  @override
  AnnictDraftStore createAnnictDraftStore(String accountKey) =>
      widget.store ?? super.createAnnictDraftStore(accountKey);

  final controller = TextEditingController();
  AnnictRatingState? rating;

  @override
  TextEditingController get draftBodyController => controller;
  @override
  AnnictDraftKind get draftKind => AnnictDraftKind.record;
  @override
  int get draftId => 42;
  @override
  Map<String, AnnictRatingState> currentDraftRatings() => {'rating': ?rating};
  @override
  void applyDraftRatings(Map<String, AnnictRatingState> ratings) =>
      rating = ratings['rating'];

  @override
  void initState() {
    super.initState();
    initAnnictDraft();
  }

  @override
  void dispose() {
    disposeAnnictDraft();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    child: Column(
      children: [
        TextField(controller: controller),
        Text('rating=${rating?.name}'),
      ],
    ),
  );
}

Future<void> _pump(WidgetTester tester, {Widget child = const _Screen()}) {
  final account = Account(
    key: const AccountKey(
      type: BackendType.mastodon,
      host: 'mstdn.example',
      username: 'me',
    ),
    adapter: _Adapter(),
    user: const User(id: 'me', username: 'me'),
    userSecret: const UserSecret(accessToken: 'token'),
  );
  return tester.pumpWidget(
    ProviderScope(
      overrides: [currentAccountProvider.overrideWithValue(account)],
      child: MaterialApp(home: child),
    ),
  );
}

Future<String?> _stored(int id) async => (await SharedPreferences.getInstance())
    .getString(AnnictDraftStore.keyFor(_me, AnnictDraftKind.record, id));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AnnictDraftStore', () {
    AnnictDraftStore store({String account = _me, int id = 1}) =>
        AnnictDraftStore(
          accountKey: account,
          kind: AnnictDraftKind.review,
          id: id,
        );

    test('保存して読み戻せる（本文と評価）', () async {
      await store().save(
        const AnnictDraft(
          body: '感想',
          ratings: {
            'overall': AnnictRatingState.great,
            'music': AnnictRatingState.bad,
          },
        ),
      );
      final d = await store().load();
      expect(d?.body, '感想');
      expect(d?.ratings, {
        'overall': AnnictRatingState.great,
        'music': AnnictRatingState.bad,
      });
    });

    test('⚠ 作品ごと・アカウントごとに分かれる', () async {
      await store().save(const AnnictDraft(body: 'A'));
      expect(await store(id: 2).load(), isNull);
      expect(await store(account: _other).load(), isNull);
      expect(
        (await SharedPreferences.getInstance()).getKeys(),
        contains(AnnictDraftStore.keyFor(_me, AnnictDraftKind.review, 1)),
      );
    });

    test('⚠ 空の下書きはキーごと消す（溜まらない）', () async {
      final s = store();
      await s.save(const AnnictDraft(body: 'A'));
      await s.save(const AnnictDraft(body: '   '));
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    });

    test('⚠ clear のあとの save は書かない（投稿後に生き返らない）', () async {
      final s = store();
      await s.save(const AnnictDraft(body: 'A'));
      final cleared = s.clear();
      final late = s.save(const AnnictDraft(body: '閉じる途中の保存'));
      await Future.wait([cleared, late]);
      expect(await store().load(), isNull);
    });

    test('壊れた値は無視する', () async {
      SharedPreferences.setMockInitialValues({
        AnnictDraftStore.keyFor(_me, AnnictDraftKind.review, 1): '{oops',
      });
      expect(await store().load(), isNull);
    });

    test('clearForAccount はそのアカウントの下書きだけ消す', () async {
      await store().save(const AnnictDraft(body: 'A'));
      await AnnictDraftStore(
        accountKey: _me,
        kind: AnnictDraftKind.record,
        id: 9,
      ).save(const AnnictDraft(body: 'B'));
      await store(account: _other).save(const AnnictDraft(body: 'C'));
      await AnnictDraftStore.clearForAccount(_me);
      expect(await store().load(), isNull);
      expect((await store(account: _other).load())?.body, 'C');
    });
  });

  group('AnnictDraftAutoSave', () {
    testWidgets('打つと少し待って保存し、開き直すと戻る', (tester) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField), '途中の感想');
      await tester.pump(AnnictDraftAutoSave.saveDelay);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(await tester.runAsync(() => _stored(42)), contains('途中の感想'));

      // 閉じて開き直す。
      await tester.pumpWidget(const SizedBox());
      await _pump(tester);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text('途中の感想'), findsOneWidget);
    });

    testWidgets('⚠ 待っている間に閉じても、その場で書く', (tester) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField), 'すぐ閉じた');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(await tester.runAsync(() => _stored(42)), contains('すぐ閉じた'));
    });

    testWidgets('⚠ 戻す前に打ち始めていたら、下書きで上書きしない', (tester) async {
      final gate = Completer<void>();
      await _pump(
        tester,
        child: _Screen(
          store: _SlowStore(
            gate,
            const AnnictDraft(
              body: '古い下書き',
              ratings: {'rating': AnnictRatingState.good},
            ),
          ),
        ),
      );
      // 読み込みが返る前に打ち、そのあとで読み込みを返す。
      await tester.enterText(find.byType(TextField), '新しく打った');
      gate.complete();
      await tester.pump();
      expect(find.text('新しく打った'), findsOneWidget);
      expect(find.text('古い下書き'), findsNothing);
      expect(find.text('rating=null'), findsOneWidget);
    });

    testWidgets('打つ前に読み込みが返れば戻す（上の対照）', (tester) async {
      final gate = Completer<void>();
      await _pump(
        tester,
        child: _Screen(
          store: _SlowStore(gate, const AnnictDraft(body: '古い下書き')),
        ),
      );
      gate.complete();
      await tester.pump();
      expect(find.text('古い下書き'), findsOneWidget);
    });

    testWidgets('評価も戻る', (tester) async {
      SharedPreferences.setMockInitialValues({
        AnnictDraftStore.keyFor(_me, AnnictDraftKind.record, 42):
            '{"body":"本文","ratings":{"rating":"great"}}',
      });
      await _pump(tester);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text('本文'), findsOneWidget);
      expect(find.text('rating=great'), findsOneWidget);
    });
  });
}
