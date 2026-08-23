import 'dart:convert';

import 'package:capsicum_backends/src/misskey/notification_streaming.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

void main() {
  group('MisskeyNotificationStreaming.parseMessage', () {
    test('main channel notification becomes a Notification', () {
      final msg = jsonEncode({
        'type': 'channel',
        'body': {
          'id': 'sub1',
          'type': 'notification',
          'body': {
            'id': 'n1',
            'type': 'follow',
            'createdAt': '2026-06-07T00:00:00.000Z',
          },
        },
      });
      final n = MisskeyNotificationStreaming.parseMessage(msg, 'example.test');
      expect(n, isNotNull);
      expect(n!.id, 'n1');
      expect(n.type, NotificationType.follow);
    });

    test('achievementEarned は実績キーを載せて変換される (#918)', () {
      final msg = jsonEncode({
        'type': 'channel',
        'body': {
          'id': 'sub1',
          'type': 'notification',
          'body': {
            'id': 'n2',
            'type': 'achievementEarned',
            'achievement': 'notes1',
            'createdAt': '2026-06-07T00:00:00.000Z',
          },
        },
      });
      final n = MisskeyNotificationStreaming.parseMessage(msg, 'example.test');
      expect(n, isNotNull);
      expect(n!.type, NotificationType.achievementEarned);
      expect(n.achievement, 'notes1');
    });

    test('announcementCreated becomes an announcement Notification', () {
      final msg = jsonEncode({
        'type': 'channel',
        'body': {
          'id': 'sub1',
          'type': 'announcementCreated',
          'body': {
            'announcement': {
              'id': 'a1',
              'title': 'お知らせ',
              'text': '本文です',
              'createdAt': '2026-06-07T00:00:00.000Z',
            },
          },
        },
      });
      final n = MisskeyNotificationStreaming.parseMessage(msg, 'example.test');
      expect(n, isNotNull);
      expect(n!.type, NotificationType.announcement);
      expect(n.id, 'announcement:a1');
      expect(n.announcement?.title, 'お知らせ');
      expect(n.announcement?.content, '本文です');
    });

    test('note channel event is ignored (timeline, null)', () {
      final msg = jsonEncode({
        'type': 'channel',
        'body': {
          'id': 'sub1',
          'type': 'note',
          'body': {'id': 'x'},
        },
      });
      expect(
        MisskeyNotificationStreaming.parseMessage(msg, 'example.test'),
        isNull,
      );
    });

    test('non-channel frame is ignored (null)', () {
      final msg = jsonEncode({'type': 'connected', 'body': {}});
      expect(
        MisskeyNotificationStreaming.parseMessage(msg, 'example.test'),
        isNull,
      );
    });
  });
}
