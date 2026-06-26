import 'package:capsicum/src/ui/util/notification_type_display.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('notificationTypeDisplay', () {
    test('mention は「メンション」に統一（「返信」と表記揺れしない）', () {
      expect(notificationTypeDisplay(NotificationType.mention).label, 'メンション');
    });

    test('reblog はラベルを注入で切替（Mastodon: ブースト / Misskey: リノート）', () {
      expect(notificationTypeDisplay(NotificationType.reblog).label, 'ブースト');
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
      expect(notificationTypeDisplay(NotificationType.follow).label, 'フォロー');
      expect(
        notificationTypeDisplay(NotificationType.reaction).label,
        'リアクション',
      );
    });

    test('announcement は「お知らせ」(#477)', () {
      expect(
        notificationTypeDisplay(NotificationType.announcement).label,
        'お知らせ',
      );
    });

    test('Collections の被フィーチャー通知にラベルが返る (#741)', () {
      expect(
        notificationTypeDisplay(NotificationType.addedToCollection).label,
        'コレクションに追加',
      );
      expect(
        notificationTypeDisplay(NotificationType.collectionUpdate).label,
        'コレクションを更新',
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

    test('Misskey 固有の type を Mastodon の enum に寄せる', () {
      // reply / quote は概念的にメンションと同じ扱い
      expect(notificationTypeFromString('reply'), NotificationType.mention);
      expect(notificationTypeFromString('quote'), NotificationType.mention);
      // pollEnded は poll に寄せる
      expect(notificationTypeFromString('pollEnded'), NotificationType.poll);
      // receiveFollowRequest は followRequest に寄せる
      expect(
        notificationTypeFromString('receiveFollowRequest'),
        NotificationType.followRequest,
      );
    });

    test('未知 / null は other', () {
      expect(notificationTypeFromString(null), NotificationType.other);
      expect(notificationTypeFromString('unknown'), NotificationType.other);
    });

    test('announcement は NotificationType.announcement (#477)', () {
      expect(
        notificationTypeFromString('announcement'),
        NotificationType.announcement,
      );
    });

    test('Mastodon 4.6 Collections の type を変換する (#741)', () {
      expect(
        notificationTypeFromString('added_to_collection'),
        NotificationType.addedToCollection,
      );
      expect(
        notificationTypeFromString('collection_update'),
        NotificationType.collectionUpdate,
      );
    });
  });
}
