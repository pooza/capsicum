import 'package:capsicum/src/service/post_account_idle_tracker.dart';
import 'package:capsicum/src/ui/util/post_account_confirm.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1306: デッキで間が空いてから投稿するとき、投稿先を確かめる。
void main() {
  group('PostAccountIdleTracker', () {
    late DateTime now;
    late PostAccountIdleTracker tracker;

    setUp(() {
      now = DateTime(2026, 11, 2, 12);
      tracker = PostAccountIdleTracker(now: () => now);
    });

    void pass(Duration d) => now = now.add(d);

    test('起動直後は再開として扱う', () {
      expect(tracker.pending, isTrue);
    });

    test('確かめたあとは、続けて操作している間は立たない', () {
      tracker.noteActivity();
      tracker.clear();

      pass(const Duration(minutes: 29));
      tracker.noteActivity();
      pass(const Duration(minutes: 29));
      tracker.noteActivity();

      expect(tracker.pending, isFalse);
    });

    test('⚠⚠ 30 分途切れたあとの最初の操作で立つ', () {
      tracker.noteActivity();
      tracker.clear();

      pass(const Duration(minutes: 30));
      expect(tracker.pending, isFalse, reason: '操作が来るまでは分からない');
      tracker.noteActivity();

      expect(tracker.pending, isTrue);
    });

    test('⚠ 立ったあとは、操作が続いても投稿先を確かめるまで下りない', () {
      tracker.noteActivity();
      tracker.clear();
      pass(const Duration(hours: 1));
      tracker.noteActivity();

      pass(const Duration(minutes: 1));
      tracker.noteActivity();

      expect(tracker.pending, isTrue);
    });
  });

  group('shouldConfirmPostAccount', () {
    bool decide({
      bool enabled = true,
      bool deckOpen = true,
      int accountCount = 2,
      bool resumed = true,
    }) => shouldConfirmPostAccount(
      enabled: enabled,
      deckOpen: deckOpen,
      accountCount: accountCount,
      resumed: resumed,
    );

    test('条件が揃えば確かめる', () => expect(decide(), isTrue));

    test('⚠ 既定の無効なら確かめない', () {
      expect(decide(enabled: false), isFalse);
    });

    test('タブ表示では確かめない', () {
      expect(decide(deckOpen: false), isFalse);
    });

    test('アカウントが 1 つなら確かめない', () {
      expect(decide(accountCount: 1), isFalse);
    });

    test('再開でなければ確かめない', () {
      expect(decide(resumed: false), isFalse);
    });
  });
}
