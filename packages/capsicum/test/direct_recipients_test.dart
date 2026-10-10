import 'package:capsicum/src/ui/util/direct_recipients.dart';
import 'package:capsicum/src/ui/widget/direct_recipients_row.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1165: Misskey の指名の宛先を、画面で見せて外せるようにする。
///
/// 届く相手は本文のメンションではなく、宛先の一覧（利用者の id）で決まる。以前は
/// 一覧を見る手段が無く、返信先の宛先を引き継ぐと「本文から消した人にも届く」
/// ことになったので、v1.66 のレビューで引き継ぎごと外した。
void main() {
  const me = User(id: 'me', username: 'pooza');
  const alice = User(id: 'a', username: 'alice');

  Post note({
    required User author,
    PostScope scope = PostScope.direct,
    List<String> ids = const [],
  }) => Post(
    id: 'n',
    postedAt: DateTime.utc(2026, 10, 10),
    author: author,
    scope: scope,
    visibleUserIds: ids,
  );

  group('開いたときの宛先', () {
    test('⚠⚠ 指名ノートへの返信: 投稿者と、返信先の宛先を引き継ぐ', () {
      expect(
        initialDirectRecipientIds(
          replyTo: note(author: alice, ids: ['me', 'b', 'c']),
          redraft: null,
          draftRecipientIds: const [],
          me: me,
        ),
        ['a', 'b', 'c'],
        reason: '投稿者が先頭・自分は入れない',
      );
    });

    test('指名でないノートへの返信: 投稿者だけ（指名を選んだときに使う）', () {
      expect(
        initialDirectRecipientIds(
          replyTo: note(
            author: alice,
            scope: PostScope.public,
            ids: const ['x'],
          ),
          redraft: null,
          draftRecipientIds: const [],
          me: me,
        ),
        ['a'],
      );
    });

    // v1.66 リリース前レビュー（赤）: 返信先の宛先を足すと、外した人が戻る。
    test('⚠⚠ 再編集: 元の投稿の宛先だけ（返信先の宛先を足さない）', () {
      expect(
        initialDirectRecipientIds(
          replyTo: note(author: alice, ids: ['b', 'c']),
          redraft: note(author: me, ids: ['a', 'me']),
          draftRecipientIds: const ['z'],
          me: me,
        ),
        ['a'],
      );
    });

    test('⚠ サーバーの下書き: 保存した宛先を読み戻す', () {
      expect(
        initialDirectRecipientIds(
          replyTo: null,
          redraft: null,
          draftRecipientIds: const ['a', 'b', 'a', 'me'],
          me: me,
        ),
        ['a', 'b'],
        reason: '重複と自分は落とす',
      );
    });

    test('新規: 空', () {
      expect(
        initialDirectRecipientIds(
          replyTo: null,
          redraft: null,
          draftRecipientIds: const [],
          me: me,
        ),
        isEmpty,
      );
    });

    test('自分の投稿への返信: 自分は入れない', () {
      expect(
        initialDirectRecipientIds(
          replyTo: note(author: me, ids: ['a']),
          redraft: null,
          draftRecipientIds: const [],
          me: me,
        ),
        ['a'],
      );
    });
  });

  group('外せない宛先', () {
    test('⚠ 返信先の投稿者は外せない（サーバーが必ず足す）', () {
      expect(
        lockedDirectRecipientId(
          replyTo: note(author: alice),
          me: me,
        ),
        'a',
      );
    });

    test('返信でなければ無い / 自分の投稿への返信でも無い', () {
      expect(lockedDirectRecipientId(replyTo: null, me: me), isNull);
      expect(
        lockedDirectRecipientId(
          replyTo: note(author: me),
          me: me,
        ),
        isNull,
      );
    });
  });

  group('送る宛先', () {
    test('指名のときだけ送る', () {
      expect(
        directRecipientIdsToSend(
          scope: PostScope.direct,
          recipientIds: ['a', 'b', 'me'],
          me: me,
        ),
        ['a', 'b'],
      );
      for (final scope in [
        PostScope.public,
        PostScope.unlisted,
        PostScope.followersOnly,
      ]) {
        expect(
          directRecipientIdsToSend(scope: scope, recipientIds: ['a'], me: me),
          isEmpty,
          reason: '⚠ 公開範囲を指名から変えたら、宛先を送らない: $scope',
        );
      }
    });
  });

  group('送れない理由', () {
    String? problem({
      PostScope scope = PostScope.direct,
      bool hasRecipients = false,
      bool isReply = false,
      bool replyTargetIsSelf = false,
    }) => directRecipientsProblem(
      scope: scope,
      hasRecipients: hasRecipients,
      isReply: isReply,
      replyTargetIsSelf: replyTargetIsSelf,
      directLabel: '指名',
    );

    test('⚠⚠ 宛先が空の新規の指名は止める（誰にも届かない）', () {
      expect(problem(), contains('宛先がありません'));
    });

    test('宛先が 1 人でも居れば送れる', () {
      expect(problem(hasRecipients: true), isNull);
    });

    test('指名でなければ関係ない', () {
      expect(problem(scope: PostScope.public), isNull);
    });

    test('他人の投稿への返信は、宛先が空でも送れる（サーバーが投稿者を足す）', () {
      expect(problem(isReply: true), isNull);
    });

    test('⚠ 自分の投稿への返信で宛先が空なら止める（自分にしか届かない）', () {
      expect(problem(isReply: true, replyTargetIsSelf: true), isNotNull);
    });
  });

  group('宛先の行', () {
    Future<List<String>> pump(
      WidgetTester tester,
      List<DirectRecipient> recipients, {
      bool enabled = true,
      VoidCallback? onAdd,
    }) async {
      final removed = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 375,
                child: DirectRecipientsRow(
                  recipients: recipients,
                  onRemove: removed.add,
                  onAdd: onAdd ?? () {},
                  enabled: enabled,
                ),
              ),
            ),
          ),
        ),
      );
      return removed;
    }

    testWidgets('⚠⚠ 全員が見えていて、× で外せる', (tester) async {
      final removed = await pump(tester, const [
        DirectRecipient(id: 'a', user: alice),
        DirectRecipient(
          id: 'b',
          user: User(id: 'b', username: 'bob', host: 'remote.example'),
        ),
      ]);
      expect(find.text('@alice'), findsOneWidget);
      expect(find.text('@bob@remote.example'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(InputChip, '@alice'),
          matching: find.byTooltip('宛先から外す'),
        ),
      );
      expect(removed, ['a']);
    });

    testWidgets('⚠ 外せない宛先には × を出さない（理由はツールチップ）', (tester) async {
      await pump(tester, const [
        DirectRecipient(id: 'a', user: alice, locked: true),
      ]);
      final chip = tester.widget<InputChip>(
        find.widgetWithText(InputChip, '@alice'),
      );
      expect(chip.onDeleted, isNull);
      expect(find.byTooltip('返信先の投稿者には必ず届きます'), findsOneWidget);
    });

    testWidgets('⚠ 名前を取れなかった人も消さずに出し、外せる', (tester) async {
      final removed = await pump(tester, const [DirectRecipient(id: 'x')]);
      expect(find.text('不明な利用者'), findsOneWidget);
      await tester.tap(find.byTooltip('宛先から外す'));
      expect(removed, ['x']);
    });

    testWidgets('問い合わせ中は読み込み中と出す', (tester) async {
      await pump(tester, const [DirectRecipient(id: 'x', loading: true)]);
      expect(find.text('読み込み中…'), findsOneWidget);
    });

    testWidgets('空のときは、空だと分かる', (tester) async {
      await pump(tester, const []);
      expect(find.text('まだ誰も入っていません'), findsOneWidget);
    });

    testWidgets('＋ で足す口が呼ばれる・送信中は押せない', (tester) async {
      var added = 0;
      await pump(tester, const [], onAdd: () => added++);
      await tester.tap(find.byKey(directRecipientsAddKey));
      expect(added, 1);

      await pump(tester, const [], enabled: false, onAdd: () => added++);
      await tester.tap(find.byKey(directRecipientsAddKey), warnIfMissed: false);
      expect(added, 1);
    });

    testWidgets('⚠ 多くても 1 行のまま（狭幅で行を増やさない）', (tester) async {
      await pump(tester, [
        for (var i = 0; i < 12; i++)
          DirectRecipient(
            id: '$i',
            user: User(id: '$i', username: 'user_with_long_name_$i'),
          ),
      ]);
      expect(tester.takeException(), isNull, reason: 'はみ出して落ちない');
      expect(
        tester.getSize(find.byKey(directRecipientsRowKey)).height,
        lessThan(64),
      );
    });
  });
}
