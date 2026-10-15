import 'package:capsicum/src/ui/util/schedule_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1212: 予約投稿の日時の選ばせ方。投稿画面の予約と、予約投稿一覧の
/// 「時刻を変更」が共有する。
void main() {
  group('早すぎる時刻の判定', () {
    final now = DateTime(2026, 10, 14, 12);

    test('⚠ 5 分より手前は早すぎる（Mastodon は 422 で拒む）', () {
      expect(
        isScheduleTooSoon(now.add(const Duration(minutes: 4)), now: now),
        isTrue,
      );
      expect(
        isScheduleTooSoon(now.subtract(const Duration(hours: 1)), now: now),
        isTrue,
      );
    });

    test('5 分ちょうど・それより先は通す', () {
      expect(
        isScheduleTooSoon(now.add(const Duration(minutes: 5)), now: now),
        isFalse,
      );
      expect(
        isScheduleTooSoon(now.add(const Duration(days: 30)), now: now),
        isFalse,
      );
    });
  });

  group('ピッカー', () {
    Future<Future<DateTime?>> open(
      WidgetTester tester, {
      DateTime? initial,
    }) async {
      late Future<DateTime?> result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    result = pickScheduleDateTime(context, initial: initial),
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

    testWidgets('日付でやめたら null（時刻のピッカーは出さない）', (tester) async {
      final result = await open(tester);
      expect(find.text('予約投稿の日付'), findsOneWidget);

      // ⚠ このテストのアプリは日本語のローカライズを載せていない。
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await result, isNull);
      expect(find.text('予約投稿の時刻'), findsNothing);
    });

    testWidgets('⚠ いまの予約が過去でも開ける（日付の下限より前を指さない）', (tester) async {
      await open(tester, initial: DateTime(2020));

      expect(tester.takeException(), isNull);
      expect(find.text('予約投稿の日付'), findsOneWidget);
    });

    testWidgets('⚠ 早すぎる時刻を選んだら、その旨を出して null', (tester) async {
      // 既定の指し先は 1 時間後なので、いまの予約を「2 分後」にして開く。
      final soon = DateTime.now().add(const Duration(minutes: 2));
      final result = await open(tester, initial: soon);

      await tester.tap(find.text('次へ（時刻を選択）'));
      await tester.pumpAndSettle();
      expect(find.text('予約投稿の時刻'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(await result, isNull);
      expect(find.text('5分以上先の日時を指定してください'), findsOneWidget);
    });

    testWidgets('⚠⚠ 1 年より先の予約でも開ける（ほかのクライアントで作った予約）', (tester) async {
      final far = DateTime.now().add(const Duration(days: 500));
      final result = await open(tester, initial: far);

      expect(tester.takeException(), isNull, reason: '初期値が上限を超えると assert で落ちる');
      expect(find.text('予約投稿の日付'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });
  });
}
