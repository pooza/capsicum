import 'package:capsicum/src/provider/hashtag_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/ui/util/visible_timeline.dart';
import 'package:capsicum/src/ui/widget/hashtag_condition_dialog.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1209: タグ TL の条件（すべて含む / いずれかを含む / 含まない）のアプリ側。
Post _post(String id, List<String> tags, {Post? reblog}) => Post(
  id: id,
  postedAt: DateTime.utc(2026, 10, 12),
  author: const User(id: 'u', username: 'someone'),
  tags: tags,
  reblog: reblog,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('表示ラベル', () {
    test('以前からの形は変わらない', () {
      expect(hashtagSpecLabel('precure'), '#precure');
      expect(hashtagSpecLabel('nitiasa+precure'), '#nitiasa + #precure');
    });

    test('いずれか・除外', () {
      expect(hashtagSpecLabel('?a+b'), '#a / #b');
      expect(hashtagSpecLabel('a!x'), '#a − #x');
      expect(hashtagSpecLabel('x?a+b!y+z'), '#x + (#a / #b) − #y − #z');
    });
  });

  group('除外の絞り込み（サーバーが除外を受けられない Misskey のため）', () {
    final query = HashtagQuery.parse('a!x');

    test('除外のタグを持つ投稿を落とす（大小は区別しない）', () {
      expect(postExcludedByHashtagQuery(_post('1', ['a', 'X']), query), isTrue);
      expect(postExcludedByHashtagQuery(_post('2', ['a']), query), isFalse);
    });

    test('⚠ ブースト / リノートは中身の投稿のタグで見る', () {
      final renote = _post('3', const [], reblog: _post('4', ['a', 'x']));
      expect(postExcludedByHashtagQuery(renote, query), isTrue);
    });

    test('除外の無い条件では何も落とさない', () {
      expect(
        postExcludedByHashtagQuery(
          _post('5', ['a', 'x']),
          HashtagQuery.parse('a'),
        ),
        isFalse,
      );
    });

    test('⚠⚠ 除外で薄くなったページを「最後のページ」と読まない', () async {
      // 1 ページめは 2 件とも除外に当たる。続きがあるかは絞る前の件数で見る
      // ので、次のページまで取りに行く。
      final pages = <String?, List<Post>>{
        null: [
          _post('4', ['a', 'x']),
          _post('3', ['a', 'x']),
        ],
        '3': [
          _post('2', ['a']),
          _post('1', ['a', 'x']),
        ],
      };
      final asked = <String?>[];
      final state = await fetchUntilVisible(
        pageSize: 2,
        hideLivecure: false,
        fetch: (maxId) async {
          asked.add(maxId);
          return pages[maxId] ?? const [];
        },
        keep: (post) => !postExcludedByHashtagQuery(post, query),
      );

      expect(asked, [null, '3']);
      expect(state.posts.map((p) => p.id), ['2']);
      expect(state.hasMore, isTrue, reason: '2 ページめも満ページで返ってきている');
    });
  });

  // #1283: Mastodon は「すべて含む」のうちサーバーに実在しないタグを黙って落とし、
  // AND が外れた一覧を返す。返ってきた投稿を端末側で確かめ直す。
  group('「すべて含む」の確かめ直し', () {
    final query = HashtagQuery.parse('a+unused');

    test('⚠⚠ 「すべて含む」のタグを欠く投稿は一覧に残さない', () {
      expect(postKeptByHashtagQuery(_post('1', ['a']), query), isFalse);
      expect(
        postKeptByHashtagQuery(_post('2', ['a', 'unused']), query),
        isTrue,
      );
      expect(
        postKeptByHashtagQuery(_post('3', ['A', 'Unused']), query),
        isTrue,
      );
    });

    test('除外も同じ口で見る', () {
      final excluding = HashtagQuery.parse('a!x');
      expect(
        postKeptByHashtagQuery(_post('1', ['a', 'x']), excluding),
        isFalse,
      );
      expect(postKeptByHashtagQuery(_post('2', ['a']), excluding), isTrue);
    });

    test('⚠ ブースト / リノートは中身の投稿のタグで見る', () {
      final boost = _post('9', const [], reblog: _post('1', ['a', 'unused']));
      expect(postKeptByHashtagQuery(boost, query), isTrue);
      final lacking = _post('8', const [], reblog: _post('2', ['a']));
      expect(postKeptByHashtagQuery(lacking, query), isFalse);
    });

    test('AND が外れた一覧（#a の全件）が返っても、合う投稿だけを残して先へ進む', () async {
      final pages = <String?, List<Post>>{
        null: [
          _post('4', ['a']),
          _post('3', ['a']),
        ],
        '3': [
          _post('2', ['a', 'unused']),
          _post('1', ['a']),
        ],
      };
      final state = await fetchUntilVisible(
        pageSize: 2,
        hideLivecure: false,
        fetch: (maxId) async => pages[maxId] ?? const [],
        keep: (post) => postKeptByHashtagQuery(post, query),
      );

      expect(state.posts.map((p) => p.id), ['2']);
    });
  });

  test('自分の投稿をタグ TL へ差し込む判定も、新しい条件に従う', () {
    expect(postMatchesHashtagSpec(_post('1', ['a', 'b']), 'a+b'), isTrue);
    expect(postMatchesHashtagSpec(_post('2', ['b']), '?a+b'), isTrue);
    expect(postMatchesHashtagSpec(_post('3', ['c']), '?a+b'), isFalse);
    expect(postMatchesHashtagSpec(_post('4', ['a', 'x']), 'a!x'), isFalse);
    expect(postMatchesHashtagSpec(_post('5', const []), 'a'), isFalse);
  });

  group('条件のダイアログ', () {
    test('入力はカンマ・読点・空白で区切り、先頭の # を外す', () {
      expect(parseHashtagConditionInput('#a, b、 ＃c  d'), ['a', 'b', 'c', 'd']);
      expect(parseHashtagConditionInput('c++'), [
        'c++',
      ], reason: '⚠ + は区切りにしない');
      expect(parseHashtagConditionInput('  '), isEmpty);
    });

    Future<String?> open(WidgetTester tester, String spec) async {
      String? result = 'unset';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await showHashtagConditionDialog(context, spec),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // 結果は呼び出し側が OK / キャンセルのあとで読む。
      addTearDown(() => result = null);
      return Future.value(result);
    }

    testWidgets('いまの条件が 3 欄に入っている', (tester) async {
      await open(tester, 'x?a+b!z');

      expect(find.widgetWithText(TextField, 'すべて含む'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'すべて含む'))
            .controller!
            .text,
        'x',
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'いずれかを含む'))
            .controller!
            .text,
        'a, b',
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '含まない'))
            .controller!
            .text,
        'z',
      );
    });

    testWidgets('書き換えて OK を押すと、新しい spec が返る', (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result =
                    await showHashtagConditionDialog(context, 'precure'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'すべて含む'), '');
      await tester.enterText(
        find.widgetWithText(TextField, 'いずれかを含む'),
        'precure, nitiasa',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '含まない'),
        '#spoiler',
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(result, '?precure+nitiasa!spoiler');
    });

    testWidgets('⚠⚠ 含む側が空のままでは保存させない（除外だけでは TL にならない）', (tester) async {
      await open(tester, 'precure');

      await tester.enterText(find.widgetWithText(TextField, 'すべて含む'), '');
      await tester.enterText(find.widgetWithText(TextField, '含まない'), 'x');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget, reason: '閉じない');
      expect(find.textContaining('タグを 1 つ以上入れてください'), findsOneWidget);
    });
  });

  test('⚠ デッキのカラムの条件を直しても、id・位置・アカウントは変わらない', () async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': [
        'x|misskey://me@misskey.example|hashtag:a',
        'y|misskey://me@misskey.example|hashtag:b',
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    initSharedPreferencesCache(prefs);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final before = container.read(deckColumnsProvider);

    await container
        .read(deckColumnsProvider.notifier)
        .replaceTab('x', const HashtagTab('?a+c'));

    final after = container.read(deckColumnsProvider);
    expect(after.map((c) => c.id), ['x', 'y'], reason: 'フォーカスとロックは id で持っている');
    expect(after.first.account, before.first.account);
    expect(after.first.tab, const HashtagTab('?a+c'));
    expect(
      prefs.getStringList('deck_columns')!.first,
      'x|misskey://me@misskey.example|hashtag:?a+c',
    );
    // 読み戻しても同じ条件になる。
    final reread = ProviderContainer();
    addTearDown(reread.dispose);
    expect(
      reread.read(deckColumnsProvider).first.tab,
      const HashtagTab('?a+c'),
    );
  });
}
