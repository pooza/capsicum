import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1048 / #1042: `GET /api/v2/notifications` の dedup 形式を読む。
///
/// ⚠ v1 は通知 1 件ごとに `account` / `status` を丸ごと抱えていたが、v2 は
/// アカウントと投稿がトップレベルの配列に 1 回だけ載り、グループは ID で参照する。
/// 引き当てを間違えると「アイコンも本文も無い通知」が並ぶ。
void main() {
  Map<String, dynamic> account(String id, {String? name}) => {
    'id': id,
    'username': 'u$id',
    'acct': 'u$id@pf.korako.me',
    'display_name': name ?? 'user $id',
    'note': '',
    'avatar': '',
    'header': '',
    'followers_count': 0,
    'following_count': 0,
    'statuses_count': 0,
    'fields': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> status(String id, {String content = 'hello'}) => {
    'id': id,
    'uri': 'https://pf.korako.me/statuses/$id',
    'created_at': '2026-09-27T00:00:00.000Z',
    'content': content,
    'visibility': 'public',
    'sensitive': false,
    'spoiler_text': '',
    'account': account('99'),
    'media_attachments': <Map<String, dynamic>>[],
    'mentions': <Map<String, dynamic>>[],
    'tags': <Map<String, dynamic>>[],
    'emojis': <Map<String, dynamic>>[],
    'reblogs_count': 0,
    'favourites_count': 0,
    'replies_count': 0,
  };

  MastodonGroupedNotifications parse(Map<String, dynamic> json) =>
      MastodonGroupedNotifications.fromJson(json);

  List<Notification> convert(MastodonGroupedNotifications grouped) {
    final accounts = {for (final a in grouped.accounts) a.id: a};
    final statuses = {for (final s in grouped.statuses) s.id: s};
    return grouped.notificationGroups
        .map(
          (g) => g.toCapsicum(
            'pf.korako.me',
            accounts: accounts,
            statuses: statuses,
          ),
        )
        .toList();
  }

  test('代表アカウントと投稿を ID で引き当てる', () {
    final grouped = parse({
      'accounts': [account('1', name: 'あかね'), account('2', name: 'あおい')],
      'statuses': [status('500', content: 'ばんぐみ実況')],
      'notification_groups': [
        {
          'group_key': 'favourite-500',
          'notifications_count': 3,
          'type': 'favourite',
          'most_recent_notification_id': '9002',
          'page_min_id': '9000',
          'page_max_id': '9002',
          'latest_page_notification_at': '2026-09-27T01:02:03.000Z',
          'sample_account_ids': ['1', '2'],
          'status_id': '500',
        },
      ],
    });
    final notifications = convert(grouped);
    expect(notifications, hasLength(1));
    final n = notifications.single;
    expect(n.type, NotificationType.favourite);
    expect(n.post?.content, 'ばんぐみ実況');
    expect(n.sampleUsers.map((u) => u.displayName), ['あかね', 'あおい']);
    expect(n.user?.displayName, 'あかね', reason: '既存の見出しは user を読むので、先頭を必ず埋める');
  });

  test('id は most_recent_notification_id（既読マーカーが通知 ID 前提）', () {
    final n = convert(
      parse({
        'accounts': [account('1')],
        'notification_groups': [
          {
            'group_key': 'follow-1',
            'notifications_count': 1,
            'type': 'follow',
            'most_recent_notification_id': '9002',
            'page_min_id': '9002',
            'latest_page_notification_at': '2026-09-27T01:02:03.000Z',
            'sample_account_ids': ['1'],
          },
        ],
      }),
    ).single;
    expect(n.id, '9002');
    expect(n.groupKey, 'follow-1');
  });

  test('⚠ 件数は notifications_count（代表 8 人で止めない）', () {
    final n = convert(
      parse({
        'accounts': [for (var i = 1; i <= 8; i++) account('$i')],
        'statuses': [status('500')],
        'notification_groups': [
          {
            'group_key': 'favourite-500',
            'notifications_count': 42,
            'type': 'favourite',
            'most_recent_notification_id': '9100',
            'page_min_id': '9000',
            'latest_page_notification_at': '2026-09-27T01:02:03.000Z',
            'sample_account_ids': ['1', '2', '3', '4', '5', '6', '7', '8'],
            'status_id': '500',
          },
        ],
      }),
    ).single;
    expect(n.sampleUsers, hasLength(8), reason: 'サーバー側の代表上限');
    expect(
      n.groupCount,
      42,
      reason: 'sampleUsers.length で数えると 8 で止まり「8 人が…」と嘘を出す',
    );
  });

  test('時刻は latest_page_notification_at（v2 のグループに created_at は無い）', () {
    final n = convert(
      parse({
        'accounts': [account('1')],
        'notification_groups': [
          {
            'group_key': 'ungrouped-9002',
            'notifications_count': 1,
            'type': 'mention',
            'most_recent_notification_id': '9002',
            'page_min_id': '9002',
            'latest_page_notification_at': '2026-09-27T01:02:03.000Z',
            'sample_account_ids': ['1'],
          },
        ],
      }),
    ).single;
    expect(n.createdAt.toUtc(), DateTime.utc(2026, 9, 27, 1, 2, 3));
  });

  test('⚠ 時刻が取れないグループは落とす（並べ替えも相対時刻も出せない）', () {
    final grouped = parse({
      'accounts': [account('1')],
      'notification_groups': [
        {
          'group_key': 'ungrouped-9002',
          'notifications_count': 1,
          'type': 'mention',
          'most_recent_notification_id': '9002',
          'sample_account_ids': ['1'],
        },
      ],
    });
    expect(() => convert(grouped), throwsA(isA<FormatException>()));
  });

  test('引き当てられない参照は落とすが、グループ自体は残す', () {
    final n = convert(
      parse({
        'accounts': <Map<String, dynamic>>[],
        'statuses': <Map<String, dynamic>>[],
        'notification_groups': [
          {
            'group_key': 'favourite-500',
            'notifications_count': 2,
            'type': 'favourite',
            'most_recent_notification_id': '9002',
            'page_min_id': '9000',
            'latest_page_notification_at': '2026-09-27T01:02:03.000Z',
            'sample_account_ids': ['1', '2'],
            'status_id': '500',
          },
        ],
      }),
    ).single;
    expect(n.sampleUsers, isEmpty);
    expect(n.post, isNull);
    expect(n.groupCount, 2, reason: '件数はサーバーの値をそのまま出す');
  });

  test('⚠ 起点となる相手がいない種別は代表を出さない（自分が出てしまう・#1084）', () {
    final n = convert(
      parse({
        // サーバーは account に受信者本人を入れて返す。
        'accounts': [account('1', name: 'わたし')],
        'notification_groups': [
          {
            'group_key': 'ungrouped-9002',
            'notifications_count': 1,
            'type': 'moderation_warning',
            'most_recent_notification_id': '9002',
            'page_min_id': '9002',
            'latest_page_notification_at': '2026-09-27T01:02:03.000Z',
            'sample_account_ids': ['1'],
            'moderation_warning': {'id': '7', 'action': 'silence'},
          },
        ],
      }),
    ).single;
    expect(n.user, isNull);
    expect(n.sampleUsers, isEmpty);
    expect(n.moderationWarning?.action, ModerationWarningAction.silence);
  });

  test('未知の種別は other に倒し、サーバーの代替文言を持つ（#1042）', () {
    final n = convert(
      parse({
        'accounts': [account('1')],
        'notification_groups': [
          {
            'group_key': 'admin.report-7',
            'notifications_count': 1,
            'type': 'admin.report',
            'most_recent_notification_id': '9002',
            'page_min_id': '9002',
            'latest_page_notification_at': '2026-09-27T01:02:03.000Z',
            'sample_account_ids': ['1'],
            'fallback': {
              'title': '<a href="https://pf.korako.me/@u1">u1</a> が通報しました',
              'summary': 'くわしくは <a href="/">サインイン</a>',
              'description': null,
            },
          },
        ],
      }),
    ).single;
    expect(n.type, NotificationType.other);
    expect(n.fallbackTitle, contains('通報しました'));
    expect(n.fallbackBody, contains('サインイン'));
  });

  test('⚠ fallback の中身が両方 null で来ることがある（baseline でない新種別）', () {
    final n = convert(
      parse({
        'accounts': [account('1')],
        'notification_groups': [
          {
            'group_key': 'something_new-1',
            'notifications_count': 1,
            'type': 'something_new',
            'most_recent_notification_id': '9002',
            'page_min_id': '9002',
            'latest_page_notification_at': '2026-09-27T01:02:03.000Z',
            'sample_account_ids': ['1'],
            'fallback': {'title': null, 'summary': null, 'description': null},
          },
        ],
      }),
    ).single;
    expect(n.type, NotificationType.other);
    expect(n.fallbackTitle, isNull, reason: 'supported_types を送れば必ず文言が来る、ではない');
  });

  test('⚠ 同じ相手が複数回載っていたら畳む（同じアイコンが並ぶ）', () {
    final n = convert(
      parse({
        'accounts': [account('1', name: 'あかね')],
        'notification_groups': [
          {
            'group_key': 'follow-1',
            'notifications_count': 3,
            'type': 'follow',
            'most_recent_notification_id': '9002',
            'page_min_id': '9000',
            'latest_page_notification_at': '2026-09-27T01:02:03.000Z',
            // フォロー → 解除 → 再フォローで同じ相手が 3 回。
            'sample_account_ids': ['1', '1', '1'],
          },
        ],
      }),
    ).single;
    expect(n.sampleUsers, hasLength(1));
    expect(n.groupCount, 3, reason: '件数はサーバーの数え方（通知の件数）に従う');
  });
}
