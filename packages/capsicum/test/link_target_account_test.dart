import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/ui/util/link_target_account.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1312: Annict / Spotify の連携のダイアログに、どのアカウントを連携するかを出す。
void main() {
  const alice = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );

  test('サーバーの名前がまだ取れていなければ、ハンドルだけ（ホスト名を二重に出さない）', () {
    expect(linkTargetAccountLabel(alice), '@alice@mstdn.example');
  });

  testWidgets('ダイアログの本文の先頭に、見出しと対象のアカウントが出る', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: linkTargetDialogContent(alice, '本文です。')),
      ),
    );
    final text = tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText();
    expect(text, '連携するアカウント\n@alice@mstdn.example\n\n本文です。');
  });

  testWidgets('解除のダイアログは見出しを替えられる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: linkTargetDialogContent(
            alice,
            '解除します。',
            heading: '連携を解除するアカウント',
          ),
        ),
      ),
    );
    final text = tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText();
    expect(text, startsWith('連携を解除するアカウント\n@alice@mstdn.example'));
  });
}
