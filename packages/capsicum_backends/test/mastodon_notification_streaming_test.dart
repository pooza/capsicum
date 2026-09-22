import 'dart:convert';

import 'package:capsicum_backends/src/mastodon/notification_streaming.dart';
import 'package:capsicum_core/capsicum_core.dart';
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

    group('関係の切断・モデレーション警告 (#1084)', () {
      Notification parse(Map<String, dynamic> payload) =>
          MastodonNotificationStreaming.parseMessage(
            jsonEncode({'event': 'notification', 'payload': payload}),
            'example.test',
          )!;

      test('severed_relationships は event の中身を持ち、本人を user に入れない', () {
        final n = parse({
          'id': '100',
          'type': 'severed_relationships',
          'created_at': '2026-09-04T00:00:00.000Z',
          // ⚠ サーバーは受信者本人を account に入れて返す。
          'account': _account(),
          'event': {
            'id': 'e1',
            'type': 'domain_block',
            'purged': false,
            'target_name': 'opentoot.org',
            'followers_count': 1,
            'following_count': 0,
            'created_at': '2026-09-04T00:00:00.000Z',
          },
        });
        expect(n.type, NotificationType.severedRelationships);
        expect(n.user, isNull, reason: '見出しに自分のアイコンを出さない');
        expect(n.severance?.kind, RelationshipSeveranceKind.domainBlock);
        expect(n.severance?.targetName, 'opentoot.org');
        expect(n.severance?.followersCount, 1);
        expect(n.severance?.followingCount, 0);
      });

      test('事由の 3 種と未知の値を読み分ける', () {
        RelationshipSeveranceKind kindOf(String type) => parse({
          'id': '101',
          'type': 'severed_relationships',
          'created_at': '2026-09-04T00:00:00.000Z',
          'account': _account(),
          'event': {'id': 'e', 'type': type, 'target_name': 't'},
        }).severance!.kind;
        expect(kindOf('domain_block'), RelationshipSeveranceKind.domainBlock);
        expect(
          kindOf('user_domain_block'),
          RelationshipSeveranceKind.userDomainBlock,
        );
        expect(
          kindOf('account_suspension'),
          RelationshipSeveranceKind.accountSuspension,
        );
        expect(kindOf('something_new'), RelationshipSeveranceKind.unknown);
      });

      test('moderation_warning は措置と説明文を持ち、本人を user に入れない', () {
        final n = parse({
          'id': '102',
          'type': 'moderation_warning',
          'created_at': '2026-09-04T00:00:00.000Z',
          'account': _account(),
          'moderation_warning': {
            'id': 'w1',
            'action': 'mark_statuses_as_sensitive',
            'text': ' 画像に注意書きを付けてください ',
            'status_ids': ['1'],
            'created_at': '2026-09-04T00:00:00.000Z',
            'target_account': _account(),
            'appeal': null,
          },
        });
        expect(n.type, NotificationType.moderationWarning);
        expect(n.user, isNull);
        expect(n.moderationWarning?.id, 'w1');
        expect(
          n.moderationWarning?.action,
          ModerationWarningAction.markStatusesAsSensitive,
        );
        expect(n.moderationWarning?.text, '画像に注意書きを付けてください');
      });

      test('説明文が空なら null・未知の措置は unknown', () {
        final n = parse({
          'id': '103',
          'type': 'moderation_warning',
          'created_at': '2026-09-04T00:00:00.000Z',
          'account': _account(),
          'moderation_warning': {
            'id': 'w2',
            'action': 'something_new',
            'text': '',
          },
        });
        expect(n.moderationWarning?.action, ModerationWarningAction.unknown);
        expect(n.moderationWarning?.text, isNull);
      });

      test('他の種別は従来どおり account を user に入れる', () {
        final n = parse({
          'id': '104',
          'type': 'follow',
          'created_at': '2026-09-04T00:00:00.000Z',
          'account': _account(),
        });
        expect(n.user?.username, 'alice');
        expect(n.severance, isNull);
        expect(n.moderationWarning, isNull);
      });
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
