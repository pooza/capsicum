import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:capsicum_backends/src/mastodon/notification_streaming.dart';
import 'package:test/test.dart';

Map<String, dynamic> _account() => {
  'id': 'u1',
  'username': 'alice',
  'acct': 'alice',
  'display_name': 'Alice',
  'note': '',
  'avatar': 'https://example.test/a.png',
  'header': 'https://example.test/h.png',
  'followers_count': 0,
  'following_count': 0,
  'statuses_count': 0,
};

void main() {
  group('MastodonNotificationStreaming.parseMessage', () {
    test('notification event becomes a Notification', () {
      final msg = jsonEncode({
        'event': 'notification',
        'payload': {
          'id': '42',
          'type': 'favourite',
          'created_at': '2026-06-07T00:00:00.000Z',
          'account': _account(),
        },
      });
      final n = MastodonNotificationStreaming.parseMessage(msg, 'example.test');
      expect(n, isNotNull);
      expect(n!.id, '42');
      expect(n.type, NotificationType.favourite);
      expect(n.user?.username, 'alice');
    });

    test('announcement event becomes an announcement Notification', () {
      final msg = jsonEncode({
        'event': 'announcement',
        'payload': {
          'id': '7',
          'content': '<p>メンテのお知らせ</p>',
          'published_at': '2026-06-07T00:00:00.000Z',
          'all_day': false,
          'read': false,
        },
      });
      final n = MastodonNotificationStreaming.parseMessage(msg, 'example.test');
      expect(n, isNotNull);
      expect(n!.type, NotificationType.announcement);
      // notification.id と名前空間を分けるため prefix する。
      expect(n.id, 'announcement:7');
      expect(n.announcement?.content, '<p>メンテのお知らせ</p>');
    });

    test('added_to_collection event carries the target collection (#741)', () {
      final msg = jsonEncode({
        'event': 'notification',
        'payload': {
          'id': '99',
          'type': 'added_to_collection',
          'created_at': '2026-06-07T00:00:00.000Z',
          'account': _account(),
          'collection': {
            'id': 'c1',
            'name': 'おすすめ',
            'url': 'https://example.test/collections/c1',
            'item_count': 5,
          },
        },
      });
      final n = MastodonNotificationStreaming.parseMessage(msg, 'example.test');
      expect(n, isNotNull);
      expect(n!.type, NotificationType.addedToCollection);
      expect(n.collection?.id, 'c1');
      expect(n.collection?.name, 'おすすめ');
      expect(n.collection?.itemCount, 5);
    });

    test('update event is ignored (out of scope, null)', () {
      final msg = jsonEncode({'event': 'update', 'payload': '{}'});
      expect(
        MastodonNotificationStreaming.parseMessage(msg, 'example.test'),
        isNull,
      );
    });

    test('malformed notification payload throws (observed by caller)', () {
      final msg = jsonEncode({
        'event': 'notification',
        'payload': {'id': '1'}, // type / account 欠落
      });
      expect(
        () => MastodonNotificationStreaming.parseMessage(msg, 'example.test'),
        throwsA(anything),
      );
    });
  });
}
