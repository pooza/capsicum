import 'package:capsicum/src/ui/util/moderation_notification_text.dart';
import 'package:capsicum/src/ui/util/notification_type_display.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1084: 関係の切断・モデレーション警告の通知が「通知」とだけ出ていた件。
void main() {
  final at = DateTime.utc(2026, 9, 4);

  Notification severed(RelationshipSeveranceKind kind) => Notification(
    id: '1',
    type: NotificationType.severedRelationships,
    createdAt: at,
    severance: RelationshipSeverance(
      kind: kind,
      targetName: 'opentoot.org',
      followersCount: 1,
    ),
  );

  Notification warned(ModerationWarningAction action) => Notification(
    id: '2',
    type: NotificationType.moderationWarning,
    createdAt: at,
    moderationWarning: ModerationWarning(id: 'w1', action: action),
  );

  group('関係の切断', () {
    test('管理者のドメインブロックは WebUI と同じ文言', () {
      expect(
        moderationNotificationText(
          severed(RelationshipSeveranceKind.domainBlock),
          localHost: 'mstdn.b-shock.org',
        ),
        'mstdn.b-shock.org の管理者が opentoot.org をブロックしました。'
        'これにより1フォロワーと0フォローが失われました。',
      );
    });

    test('自分のドメインブロック・アカウント停止・未知の事由', () {
      expect(
        moderationNotificationText(
          severed(RelationshipSeveranceKind.userDomainBlock),
          localHost: 'h',
        ),
        'opentoot.org のブロックにより1フォロワーと0フォローが解除されました。',
      );
      expect(
        moderationNotificationText(
          severed(RelationshipSeveranceKind.accountSuspension),
          localHost: 'h',
          postLabel: 'キュア！',
        ),
        contains('新しいキュア！の受け取りができなくなりました'),
        reason: 'サーバーの投稿ラベルに従う',
      );
      expect(
        moderationNotificationText(
          severed(RelationshipSeveranceKind.unknown),
          localHost: 'h',
        ),
        'opentoot.org との関係が失われました。',
      );
    });

    test('詳細は /severed_relationships をブラウザで開く', () {
      expect(
        moderationNotificationWebUri(
          severed(RelationshipSeveranceKind.domainBlock),
          localHost: 'mstdn.b-shock.org',
        ),
        Uri.parse('https://mstdn.b-shock.org/severed_relationships'),
      );
    });
  });

  group('モデレーション警告', () {
    test('措置ごとに文言が違い、どれも空にならない', () {
      final texts = {
        for (final a in ModerationWarningAction.values)
          a: moderationNotificationText(warned(a), localHost: 'h'),
      };
      expect(texts.values, everyElement(isNotEmpty));
      expect(
        texts.values.toSet(),
        hasLength(ModerationWarningAction.values.length),
      );
      expect(
        texts[ModerationWarningAction.deleteStatuses],
        'あなたによるいくつかの投稿が削除されました。',
      );
    });

    test('詳細は異議申し立てページ（/disputes/strikes/:id）', () {
      expect(
        moderationNotificationWebUri(
          warned(ModerationWarningAction.silence),
          localHost: 'mstdn.b-shock.org',
        ),
        Uri.parse('https://mstdn.b-shock.org/disputes/strikes/w1'),
      );
    });
  });

  test('他の種別・中身の無い通知には何も出さない', () {
    final follow = Notification(
      id: '3',
      type: NotificationType.follow,
      createdAt: at,
    );
    final empty = Notification(
      id: '4',
      type: NotificationType.severedRelationships,
      createdAt: at,
    );
    for (final n in [follow, empty]) {
      expect(moderationNotificationText(n, localHost: 'h'), isNull);
      expect(moderationNotificationWebUri(n, localHost: 'h'), isNull);
    }
  });

  test('種別名は「通知」に落ちない・push の type 文字列も読む', () {
    expect(
      notificationTypeDisplay(NotificationType.severedRelationships).label,
      '関係が失われました',
    );
    expect(
      notificationTypeDisplay(NotificationType.moderationWarning).label,
      '管理者からの警告',
    );
    expect(
      notificationTypeFromString('severed_relationships'),
      NotificationType.severedRelationships,
    );
    expect(
      notificationTypeFromString('moderation_warning'),
      NotificationType.moderationWarning,
    );
  });
}
