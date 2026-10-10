import 'dart:io';

import 'package:capsicum/src/ui/widget/report_comment_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1203: 通報ダイアログの「相手のサーバーの管理者にも知らせる」。
///
/// ⚠ **既定はオン。**転送しない通報は自分のサーバーの管理者にしか届かず、
/// リモートの相手を止められる人には伝わらない。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// ダイアログを開き、閉じたときの結果を受け取る口を返す。
  Future<ReportInput? Function()> open(
    WidgetTester tester, {
    String? forwardHost,
  }) async {
    ReportInput? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showReportCommentDialog(
                context,
                message: '通報しますか？',
                forwardHost: forwardHost,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, '通報'));
    await tester.pumpAndSettle();
  }

  testWidgets('転送先があると、サーバー名つきのチェックが既定オンで出る', (tester) async {
    final result = await open(tester, forwardHost: 'remote.example');

    expect(find.text('remote.example の管理者にも知らせる'), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );

    await tester.enterText(find.byType(TextField), ' spam ');
    await submit(tester);

    expect(result(), (comment: 'spam', forward: true));
  });

  testWidgets('チェックを外すと forward は false で返る', (tester) async {
    final result = await open(tester, forwardHost: 'remote.example');

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await submit(tester);

    expect(result(), (comment: '', forward: false));
  });

  testWidgets('⚠ 転送先が無ければチェックを出さず、forward は false', (tester) async {
    final result = await open(tester);

    expect(find.byType(CheckboxListTile), findsNothing);

    await submit(tester);

    expect(result(), (comment: '', forward: false));
  });

  testWidgets('キャンセルは null', (tester) async {
    final result = await open(tester, forwardHost: 'remote.example');

    await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
    await tester.pumpAndSettle();

    expect(result(), isNull);
  });

  /// ダイアログが返しても、画面が捨てれば相手のサーバーへは届かない。通報は
  /// 2 画面から出るので、両方が転送先を渡し、結果を送っていることを見る。
  group('通報の 2 画面が転送の指定を通している', () {
    for (final path in [
      'lib/src/ui/widget/post_tile.dart',
      'lib/src/ui/screen/profile_screen.dart',
    ]) {
      test(path, () {
        final src = File(path).readAsStringSync();
        expect(
          src,
          contains('.reportForwardHost('),
          reason: '転送先をダイアログへ渡していない ＝ チェックが出ない',
        );
        expect(
          src,
          contains('forward: input.forward'),
          reason: 'ダイアログの結果を通報へ渡していない ＝ 押しても転送されない',
        );
      });
    }
  });
}
