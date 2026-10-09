import 'package:capsicum/src/ui/widget/emoji_picker.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1175: 絵文字ピッカーの検索語を、タブを移ったときに持ち越す。
///
/// 検索ボックスはタブごとに独立していて、同じ語を各タブで打ち直していた
/// （2026-09-23 pooza）。⚠ **劇中ワードだけはモロヘイヤを引く**ので、打鍵の
/// たびに 3 つへ流す形にはしない —— そのタブを開いたときに引く。
class _Adapter extends Mock implements BackendAdapter {}

class _Mulukhiya extends Mock implements MulukhiyaService {}

void main() {
  late _Mulukhiya mulukhiya;
  late List<String> wordQueries;

  setUp(() {
    wordQueries = [];
    mulukhiya = _Mulukhiya();
    when(() => mulukhiya.wordSuggestEnabled).thenReturn(true);
    when(() => mulukhiya.prewarmWordDictionary()).thenAnswer((_) async {});
    when(
      () => mulukhiya.suggestWordsLocal(
        q: any(named: 'q'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((invocation) async {
      wordQueries.add(invocation.namedArguments[#q] as String);
      return const <WordSuggestion>[];
    });
  });

  /// カスタム絵文字に対応しないアダプタなので、タブは Unicode / 劇中ワードの 2 つ。
  Future<void> pumpPicker(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: EmojiPicker(
              adapter: _Adapter(),
              host: 'example.com',
              mulukhiya: mulukhiya,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String searchTextOf(WidgetTester tester, String hint) => tester
      .widget<TextField>(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == hint,
        ),
      )
      .controller!
      .text;

  const unicodeHint = '絵文字を検索…';
  const wordHint = '読みで検索…（例: せんかれっこうけん）';

  testWidgets('🔴 Unicode で打った語が、劇中ワードへ移ると入っている', (tester) async {
    await pumpPicker(tester);

    await tester.enterText(find.byType(TextField).first, ' せんか ');
    await tester.pump();

    await tester.tap(find.text('劇中ワード'));
    await tester.pumpAndSettle();

    // ⚠ 打った生の文字を運ぶ（前後の空白も落とさない。正規化は検索の側）。
    expect(searchTextOf(tester, wordHint), ' せんか ');

    // 開いた時点で、その語で引く（劇中ワードは trim して引く）。
    await tester.pump(const Duration(milliseconds: 300));
    expect(wordQueries, ['せんか']);
  });

  testWidgets('⚠⚠ 別のタブで打っている間は、劇中ワードを引かない', (tester) async {
    await pumpPicker(tester);

    await tester.enterText(find.byType(TextField).first, 'せ');
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'せん');
    await tester.pump(const Duration(seconds: 1));

    expect(wordQueries, isEmpty, reason: '打鍵のたびにモロヘイヤへ出さない');
  });

  testWidgets('戻るときも持ち越す（劇中ワードで直した語が Unicode に入る）', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.text('劇中ワード'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == wordHint,
      ),
      'Cat',
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Unicode'));
    await tester.pumpAndSettle();

    expect(searchTextOf(tester, unicodeHint), 'Cat');
  });

  testWidgets('空のまま移っても、移った先を空のままにする（引かない）', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.text('劇中ワード'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    expect(searchTextOf(tester, wordHint), isEmpty);
    expect(wordQueries, isEmpty);
  });
}
