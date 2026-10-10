import 'package:capsicum/src/provider/unread_badge_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1207: アカウント切替のバッジに、通知の未読数をサーバーの値で出す。
///
/// ⚠ v1.19 から `notifications` は常に 0 で、お知らせの未読だけが出ていた
/// （書き込み経路を撤去したまま）。**0 のまま戻っても画面は壊れない**ので、
/// 値が通っていることをここで固定する。
class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        NotificationUnreadCountSupport,
        AnnouncementSupport {
  _Adapter({this.unread = 0, this.announcements = const []});

  final int unread;
  final List<Announcement> announcements;
  bool failUnread = false;
  bool failAnnouncements = false;

  @override
  Future<int> getUnreadNotificationCount() async {
    if (failUnread) throw Exception('404');
    return unread;
  }

  @override
  Future<List<Announcement>> getAnnouncements() async {
    if (failAnnouncements) throw Exception('boom');
    return announcements;
  }
}

/// 未読数の口を持たないバックエンド。
class _AnnouncementOnly extends Mock
    implements DecentralizedBackendAdapter, AnnouncementSupport {
  @override
  Future<List<Announcement>> getAnnouncements() async => [_ann('a1')];
}

Announcement _ann(String id, {bool read = false}) => Announcement(
  id: id,
  content: 'body',
  publishedAt: DateTime(2026, 10, 9),
  read: read,
);

void main() {
  test('通知の未読数がサーバーの値で入る', () async {
    final badge = await fetchUnreadBadge(_Adapter(unread: 5));

    expect(badge.notifications, 5);
    expect(badge.announcements, 0);
    expect(badge.total, 5);
    expect(badge.hasUnread, isTrue);
  });

  test('お知らせの未読と足し合わせる（既読のお知らせは数えない）', () async {
    final badge = await fetchUnreadBadge(
      _Adapter(
        unread: 2,
        announcements: [_ann('a1'), _ann('a2', read: true), _ann('a3')],
      ),
    );

    expect(badge.notifications, 2);
    expect(badge.announcements, 2);
    expect(badge.total, 4);
  });

  test('どちらも 0 ならバッジは出ない', () async {
    final badge = await fetchUnreadBadge(_Adapter());

    expect(badge.hasUnread, isFalse);
  });

  test('⚠ 未読数が取れなくても、お知らせの未読は出す（古いサーバーは 404）', () async {
    final adapter = _Adapter(unread: 9, announcements: [_ann('a1')])
      ..failUnread = true;

    final badge = await fetchUnreadBadge(adapter);

    expect(badge.notifications, 0);
    expect(badge.announcements, 1);
  });

  test('⚠ お知らせが取れなくても、通知の未読数は出す', () async {
    final adapter = _Adapter(unread: 4)..failAnnouncements = true;

    final badge = await fetchUnreadBadge(adapter);

    expect(badge.notifications, 4);
    expect(badge.announcements, 0);
  });

  test('未読数の口を持たないバックエンドでは 0（お知らせだけ出る）', () async {
    final badge = await fetchUnreadBadge(_AnnouncementOnly());

    expect(badge.notifications, 0);
    expect(badge.announcements, 1);
  });
}
