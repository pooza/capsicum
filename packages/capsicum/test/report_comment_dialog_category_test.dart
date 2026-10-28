import 'dart:async';

import 'package:capsicum/src/ui/widget/report_comment_dialog.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1257: 通報に分類と違反したルールを添える（2026-10-27 pooza 判断）。
///
/// - 既定は「その他」。触らなければ分類を足す前と同じ手数で送れる
/// - 「サーバーのルール違反」はルールが 1 件以上あるときだけ出し、選んだら
///   ルールを 1 つ以上選ぶまで送れない（添えずに送るとサーバーが断る）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rules = [
    ReportRule(id: '1', text: '差別をしない', hint: '補足'),
    ReportRule(id: '2', text: 'スパムをしない'),
  ];

  Future<ReportInput? Function()> open(
    WidgetTester tester, {
    Future<List<ReportRule>>? rules,
  }) async {
    ReportInput? result;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showReportCommentDialog(
                  context,
                  message: '通報しますか？',
                  rules: rules,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Finder submitButton() => find.widgetWithText(TextButton, '通報');

  Future<void> choose(WidgetTester tester, ReportCategory category) async {
    await tester.tap(find.byType(DropdownButtonFormField<ReportCategory>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(reportCategoryLabels[category]!).last);
    await tester.pumpAndSettle();
  }

  testWidgets('ルールを渡さなければ（Misskey）分類を出さず、「その他」で返る', (tester) async {
    final result = await open(tester);

    expect(find.text('分類'), findsNothing);
    await tester.tap(submitButton());
    await tester.pumpAndSettle();

    expect(result()?.category, ReportCategory.other);
    expect(result()?.ruleIds, isEmpty);
  });

  testWidgets('既定は「その他」で、触らなければそのまま送れる', (tester) async {
    final result = await open(tester, rules: Future.value(rules));

    expect(find.text('分類'), findsOneWidget);
    expect(find.text('その他'), findsOneWidget);
    await tester.tap(submitButton());
    await tester.pumpAndSettle();

    expect(result()?.category, ReportCategory.other);
    expect(result()?.ruleIds, isEmpty);
  });

  testWidgets('「スパム」を選ぶとスパムで返り、ルールは添えない', (tester) async {
    final result = await open(tester, rules: Future.value(rules));

    await choose(tester, ReportCategory.spam);
    await tester.tap(submitButton());
    await tester.pumpAndSettle();

    expect(result()?.category, ReportCategory.spam);
    expect(result()?.ruleIds, isEmpty);
  });

  testWidgets('⚠⚠ 「サーバーのルール違反」はルールを選ぶまで送れず、選んだルールが返る', (tester) async {
    final result = await open(tester, rules: Future.value(rules));

    await choose(tester, ReportCategory.violation);
    expect(find.text('差別をしない'), findsOneWidget);
    expect(find.text('補足'), findsOneWidget);
    expect(
      tester.widget<TextButton>(submitButton()).onPressed,
      isNull,
      reason: 'ルールを選ぶまで押せない',
    );

    await tester.tap(find.text('スパムをしない'));
    await tester.pump();
    expect(tester.widget<TextButton>(submitButton()).onPressed, isNotNull);
    await tester.tap(submitButton());
    await tester.pumpAndSettle();

    expect(result()?.category, ReportCategory.violation);
    expect(result()?.ruleIds, ['2']);
  });

  testWidgets('⚠ ルールが 0 件なら「サーバーのルール違反」を出さない', (tester) async {
    await open(tester, rules: Future.value(const []));

    await tester.tap(find.byType(DropdownButtonFormField<ReportCategory>));
    await tester.pumpAndSettle();

    expect(find.text('スパム'), findsWidgets, reason: '一覧は開いている');
    expect(find.text('サーバーのルール違反'), findsNothing);
  });

  testWidgets('⚠ ルールが読めなくても通報はできる', (tester) async {
    // ⚠ ダイアログが受け取ってからエラーで完了させる（先に作ると、受け手の
    // いないエラーとしてテストが拾う）。
    final loading = Completer<List<ReportRule>>();
    final result = await open(tester, rules: loading.future);
    loading.completeError(Exception('404'));
    await tester.pumpAndSettle();

    await tester.tap(submitButton());
    await tester.pumpAndSettle();

    expect(result()?.category, ReportCategory.other);
  });

  // v2.7 のリリース前レビュー: 2 画面に写されていた判定を 1 つに集めた。
  group('reportRulesFor', () {
    test('分類を添えられるバックエンドだけルールを読む', () async {
      final adapter = _Report(category: true);
      final rules = await reportRulesFor(adapter);
      expect(rules, hasLength(1));
      expect(adapter.rulesRead, 1);
    });

    test('⚠ 添えられないバックエンドでは読まず null（分類を出さない）', () {
      final adapter = _Report(category: false);
      expect(reportRulesFor(adapter), isNull);
      expect(adapter.rulesRead, 0);
    });
  });
}

/// [reportRulesFor] の確かめ用。分類を添えられるかと、ルールを読んだ回数だけ持つ。
class _Report with ReportSupport {
  _Report({required this.category});

  final bool category;
  int rulesRead = 0;

  @override
  bool get supportsReportCategory => category;

  @override
  Future<List<ReportRule>> getReportRules() async {
    rulesRead++;
    return const [ReportRule(id: '1', text: 'ルール')];
  }

  @override
  Future<void> reportPost(
    String postId,
    String authorId, {
    String? comment,
    bool forward = false,
    ReportCategory category = ReportCategory.other,
    List<String> ruleIds = const [],
  }) async {}

  @override
  Future<void> reportUser(
    String userId, {
    String? comment,
    bool forward = false,
    ReportCategory category = ReportCategory.other,
    List<String> ruleIds = const [],
  }) async {}
}
