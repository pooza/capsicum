// #1411: 通知の種類ごとにプッシュ通知をオン / オフする（Mastodon 系だけ）。
import 'package:capsicum/src/service/push_muted_alerts.dart';
import 'package:capsicum/src/ui/screen/settings/push_notification_settings_screen.dart';
import 'package:capsicum/src/ui/util/notification_type_display.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const a = 'mastodon://a@x.example';
  const b = 'mastodon://b@y.example';

  group('PushMutedAlerts', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      initSharedPreferencesCache(await SharedPreferences.getInstance());
    });
    tearDown(() => debugSetSharedPreferencesCache(null));

    test('既定は空（全部受け取る）', () {
      expect(PushMutedAlerts.mutedFor(a), isEmpty);
    });

    test('アカウントごとに持つ', () async {
      await PushMutedAlerts.setMuted(a, {PushAlertCategory.favourite});

      expect(PushMutedAlerts.mutedFor(a), {PushAlertCategory.favourite});
      expect(PushMutedAlerts.mutedFor(b), isEmpty);
    });

    test('空に戻すと消え、全員が空ならキーごと消す', () async {
      await PushMutedAlerts.setMuted(a, {PushAlertCategory.reblog});
      await PushMutedAlerts.setMuted(a, const {});

      expect(PushMutedAlerts.mutedFor(a), isEmpty);
      expect(sharedPrefsOrThrow.containsKey(PushMutedAlerts.prefsKey), isFalse);
    });

    test('⚠ 知らない分類の名前は読み飛ばす（版を戻したとき）', () async {
      await sharedPrefsOrThrow.setString(
        PushMutedAlerts.prefsKey,
        '{"$a": ["favourite", "future_kind"]}',
      );

      expect(PushMutedAlerts.mutedFor(a), {PushAlertCategory.favourite});
    });

    test('⚠ 読めなければ空（黙って通知を止めない）', () {
      debugSetSharedPreferencesCache(null);
      expect(PushMutedAlerts.mutedFor(a), isEmpty);
    });

    test('削除で捨てる。⚠ 投げない', () async {
      await PushMutedAlerts.setMuted(a, {PushAlertCategory.poll});
      await PushMutedAlerts.forget(a);
      expect(PushMutedAlerts.mutedFor(a), isEmpty);

      debugSetSharedPreferencesCache(null);
      await PushMutedAlerts.forget(a);
    });
  });

  test('分類の名前は通知の一覧と同じ', () {
    expect(pushAlertCategoryLabel(PushAlertCategory.mention), 'メンション');
    expect(pushAlertCategoryLabel(PushAlertCategory.favourite), 'お気に入り');
    expect(pushAlertCategoryLabel(PushAlertCategory.follow), 'フォロー・フォローリクエスト');
  });

  group('種類のシート', () {
    Future<Set<PushAlertCategory>?> openAndPop(
      WidgetTester tester,
      Set<PushAlertCategory> initial,
      Future<void> Function() act,
    ) async {
      Set<PushAlertCategory>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<Set<PushAlertCategory>>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => PushAlertTypesSheet(initialMuted: initial),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await act();
      return result;
    }

    testWidgets('切ったものを「完了」で返す', (tester) async {
      final result = await openAndPop(tester, const {}, () async {
        await tester.tap(find.byKey(const ValueKey('push-alert-favourite')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('push-alert-types-done')),
        );
        await tester.tap(find.byKey(const ValueKey('push-alert-types-done')));
        await tester.pumpAndSettle();
      });

      expect(result, {PushAlertCategory.favourite});
    });

    testWidgets('切ってあったものを戻せる', (tester) async {
      final result = await openAndPop(
        tester,
        {PushAlertCategory.reblog},
        () async {
          await tester.tap(find.byKey(const ValueKey('push-alert-reblog')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('push-alert-types-done')),
          );
          await tester.tap(find.byKey(const ValueKey('push-alert-types-done')));
          await tester.pumpAndSettle();
        },
      );

      expect(result, isEmpty);
    });
  });
}
