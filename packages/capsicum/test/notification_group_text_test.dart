import 'package:capsicum/src/ui/util/notification_group_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1048: 「10 人がお気に入りしました」形式の文字列。
void main() {
  group('notificationActorSuffix', () {
    test('1 件なら従来どおり（人数を出さない）', () {
      expect(notificationActorSuffix(groupCount: 1, label: 'お気に入り'), ' がお気に入り');
    });

    test('0 件・負の件数でも 1 件と同じ形に倒す', () {
      expect(notificationActorSuffix(groupCount: 0, label: 'お気に入り'), ' がお気に入り');
      expect(
        notificationActorSuffix(groupCount: -1, label: 'お気に入り'),
        ' がお気に入り',
      );
    });

    test('2 件なら「ほか 1 人」（代表の 1 人を引く）', () {
      expect(
        notificationActorSuffix(groupCount: 2, label: 'お気に入り'),
        ' ほか1人がお気に入り',
      );
    });

    test('42 件なら「ほか 41 人」', () {
      expect(
        notificationActorSuffix(groupCount: 42, label: 'ブースト'),
        ' ほか41人がブースト',
      );
    });

    test('ラベルは呼び出し側が決める（ブースト / リノートの差を持ち込まない）', () {
      expect(
        notificationActorSuffix(groupCount: 3, label: 'リノート'),
        ' ほか2人がリノート',
      );
    });
  });

  group('notificationActorlessLabel', () {
    test('1 件ならラベルだけ', () {
      expect(notificationActorlessLabel(groupCount: 1, label: 'フォロー'), 'フォロー');
    });

    test('⚠ 代表が居ないときは「 ほか…」で始めない', () {
      final text = notificationActorlessLabel(groupCount: 5, label: 'フォロー');
      expect(text, '5人がフォロー');
      expect(
        text.startsWith(' ほか'),
        isFalse,
        reason: '代表を引き当てられなかったグループで先頭が「 ほか」になると読めない',
      );
    });
  });
}
