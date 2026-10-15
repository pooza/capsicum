import 'package:capsicum/src/ui/widget/list_settings_dialog.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1211: リストの設定のダイアログ。接続先が持つ項目だけを出し、変えた項目だけを
/// 返す。
void main() {
  const mastodonList = PostList(
    id: '1',
    title: '家族',
    repliesPolicy: ListRepliesPolicy.list,
    exclusive: false,
  );
  const misskeyList = PostList(id: 'l1', title: '家族', isPublic: false);

  Future<Future<ListSettingsChange?>> open(
    WidgetTester tester,
    PostList list,
  ) async {
    late Future<ListSettingsChange?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => result = showListSettingsDialog(context, list),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Mastodon: 返信の範囲とホームからの排他を出し、公開は出さない', (tester) async {
    await open(tester, mastodonList);

    expect(find.text('このリストに表示する返信'), findsOneWidget);
    for (final label in listRepliesPolicyLabels.values) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('メンバーの投稿をホームに表示しない'), findsOneWidget);
    expect(find.text('公開する'), findsNothing);
  });

  testWidgets('Misskey: 公開だけを出す', (tester) async {
    await open(tester, misskeyList);

    expect(find.text('公開する'), findsOneWidget);
    expect(find.text('このリストに表示する返信'), findsNothing);
    expect(find.text('メンバーの投稿をホームに表示しない'), findsNothing);
  });

  testWidgets('⚠ いまの値が選ばれた状態で開く', (tester) async {
    await open(
      tester,
      const PostList(
        id: '1',
        title: '家族',
        repliesPolicy: ListRepliesPolicy.none,
        exclusive: true,
      ),
    );

    final selected = find.ancestor(
      of: find.byIcon(Icons.radio_button_checked),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: selected, matching: find.text('表示しない')),
      findsOneWidget,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
  });

  testWidgets('⚠⚠ 変えた項目だけを返す（変えていない項目は null）', (tester) async {
    final result = await open(tester, mastodonList);

    await tester.tap(find.text('メンバーの投稿をホームに表示しない'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final change = await result;
    expect(change!.exclusive, isTrue);
    expect(change.repliesPolicy, isNull, reason: '触っていない項目は送らない');
    expect(change.isPublic, isNull);
  });

  testWidgets('返信の範囲を変えて保存する', (tester) async {
    final result = await open(tester, mastodonList);

    await tester.tap(find.text('フォローしている人への返信'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final change = await result;
    expect(change!.repliesPolicy, ListRepliesPolicy.followed);
    expect(change.exclusive, isNull);
  });

  testWidgets('⚠ 何も変えずに保存したら null（更新を送らない）', (tester) async {
    final result = await open(tester, misskeyList);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(await result, isNull);
  });

  testWidgets('⚠ 変えて元に戻してから保存しても null', (tester) async {
    final result = await open(tester, misskeyList);

    await tester.tap(find.text('公開する'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公開する'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(await result, isNull);
  });

  testWidgets('キャンセルしたら null', (tester) async {
    final result = await open(tester, misskeyList);

    await tester.tap(find.text('公開する'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    expect(await result, isNull);
  });
}
