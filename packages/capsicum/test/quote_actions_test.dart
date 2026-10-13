import 'package:capsicum/src/ui/util/compose_settings_display.dart';
import 'package:capsicum/src/ui/util/quote_actions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1213: 引用された側・引用を許す側の道具を、どの投稿に出すか。
const _me = User(id: 'me', username: 'me');
const _other = User(id: 'other', username: 'other');

Post _post({
  required User author,
  Post? quote,
  String? quoteApprovalPolicy,
  PostScope scope = PostScope.public,
}) => Post(
  id: 'p',
  postedAt: DateTime.utc(2026, 10, 14),
  author: author,
  quote: quote,
  quoteApprovalPolicy: quoteApprovalPolicy,
  scope: scope,
);

void main() {
  group('この引用を撤回', () {
    test('⚠⚠ 自分の投稿を引用している他人の投稿に出す', () {
      final quoting = _post(
        author: _other,
        quote: _post(author: _me),
      );
      expect(canRevokeQuote(quoting, _me), isTrue);
    });

    test('⚠ 他人の投稿を引用している投稿には出さない（撤回できるのは引用された側だけ）', () {
      final quoting = _post(
        author: _other,
        quote: _post(author: _other),
      );
      expect(canRevokeQuote(quoting, _me), isFalse);
    });

    test('自分の投稿には出さない（自分の引用は、投稿を消せば外れる）', () {
      final selfQuote = _post(
        author: _me,
        quote: _post(author: _me),
      );
      expect(canRevokeQuote(selfQuote, _me), isFalse);
    });

    test('引用していない投稿・引用先が見えていない投稿には出さない', () {
      expect(canRevokeQuote(_post(author: _other), _me), isFalse);
    });

    test('ログインしていなければ出さない', () {
      final quoting = _post(
        author: _other,
        quote: _post(author: _me),
      );
      expect(canRevokeQuote(quoting, null), isFalse);
    });
  });

  group('引用の許可を変更', () {
    test('自分の公開・未収載の投稿に出す', () {
      for (final scope in [PostScope.public, PostScope.unlisted]) {
        expect(
          canChangeQuoteApproval(
            _post(author: _me, quoteApprovalPolicy: 'public', scope: scope),
            _me,
          ),
          isTrue,
          reason: '$scope',
        );
      }
    });

    test('⚠ フォロワー限定・指名の投稿には出さない（サーバーが引用を許さない）', () {
      for (final scope in [PostScope.followersOnly, PostScope.direct]) {
        expect(
          canChangeQuoteApproval(
            _post(author: _me, quoteApprovalPolicy: 'nobody', scope: scope),
            _me,
          ),
          isFalse,
          reason: '$scope',
        );
      }
    });

    test('⚠ 引用の許可を返さないサーバー（4.5 未満・Misskey）には出さない', () {
      expect(canChangeQuoteApproval(_post(author: _me), _me), isFalse);
    });

    test('他人の投稿には出さない', () {
      expect(
        canChangeQuoteApproval(
          _post(author: _other, quoteApprovalPolicy: 'public'),
          _me,
        ),
        isFalse,
      );
    });
  });

  group('ダイアログ', () {
    Future<Future<T>> open<T>(
      WidgetTester tester,
      Future<T> Function(BuildContext context) show,
    ) async {
      late Future<T> result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => result = show(context),
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

    testWidgets('撤回は、取り消せないことを伝えてから確かめる', (tester) async {
      final result = await open(tester, confirmRevokeQuote);
      expect(find.textContaining('撤回は取り消せません'), findsOneWidget);

      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
    });

    testWidgets('⚠ 撤回の確認を枠の外で閉じたら、撤回しない', (tester) async {
      final result = await open(tester, confirmRevokeQuote);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });

    testWidgets('許可は 3 つから選び、選んだ値を返す', (tester) async {
      final result = await open(
        tester,
        (context) => pickQuoteApprovalPolicy(context, current: 'public'),
      );
      for (final label in quoteApprovalLabels.values) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.text('許可しない'));
      await tester.pumpAndSettle();
      expect(await result, 'nobody');
    });

    testWidgets('⚠ いまと同じ値を選んだら、変えない（null）', (tester) async {
      final result = await open(
        tester,
        (context) => pickQuoteApprovalPolicy(context, current: 'followers'),
      );

      await tester.tap(find.text('フォロワーのみ'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });
  });
}
