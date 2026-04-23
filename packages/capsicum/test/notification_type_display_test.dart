import 'package:capsicum/src/ui/util/notification_type_display.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('notificationTypeDisplay', () {
    test('mention は「メンション」に統一（「返信」と表記揺れしない）', () {
      expect(
        notificationTypeDisplay(NotificationType.mention).label,
        'メンション',
      );
    });

    test('reblog はラベルを注入で切替（Mastodon: ブースト / Misskey: リノート）', () {
      expect(
        notificationTypeDisplay(NotificationType.reblog).label,
        'ブースト',
      );
      expect(
        notificationTypeDisplay(
          NotificationType.reblog,
          reblogLabel: 'リノート',
        ).label,
        'リノート',
      );
    });

    test('その他の type もラベルが返る', () {
      expect(
        notificationTypeDisplay(NotificationType.favourite).label,
        'お気に入り',
      );
      expect(
        notificationTypeDisplay(NotificationType.follow).label,
        'フォロー',
      );
      expect(
        notificationTypeDisplay(NotificationType.reaction).label,
        'リアクション',
      );
    });
  });

  group('notificationTypeFromString', () {
    test('既知の文字列を enum に変換', () {
      expect(notificationTypeFromString('mention'), NotificationType.mention);
      expect(notificationTypeFromString('reblog'), NotificationType.reblog);
      expect(notificationTypeFromString('renote'), NotificationType.reblog);
      expect(
        notificationTypeFromString('favourite'),
        NotificationType.favourite,
      );
      expect(
        notificationTypeFromString('follow_request'),
        NotificationType.followRequest,
      );
    });

    test('未知 / null は other', () {
      expect(notificationTypeFromString(null), NotificationType.other);
      expect(notificationTypeFromString('unknown'), NotificationType.other);
    });
  });
}
