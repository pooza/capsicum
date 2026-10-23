import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1321: Mastodon 5.0 でサーバーがお知らせのリアクションを無効にできるようになり、
/// `reactions_allowed` が増えた。無効のお知らせでは追加ボタンを出さない。
///
/// ⚠ 4.7 以前はフィールドが無い。**無いときは許可として扱う**（無効と読むと、
/// いまのプリセットの全サーバーでリアクションが押せなくなる）。
void main() {
  MastodonAnnouncement announcement(Map<String, dynamic> overrides) =>
      MastodonAnnouncement.fromJson({
        'id': '1',
        'content': '<p>お知らせ</p>',
        'all_day': false,
        'published_at': '2026-10-24T00:00:00Z',
        'read': false,
        'reactions': <Map<String, dynamic>>[],
        ...overrides,
      });

  group('reactions_allowed → Announcement.reactionsAllowed', () {
    test('フィールドが無い（4.7 以前）ときは許可として扱う', () {
      expect(announcement({}).toCapsicum().reactionsAllowed, isTrue);
    });

    test('true ならそのまま許可', () {
      expect(
        announcement({'reactions_allowed': true}).toCapsicum().reactionsAllowed,
        isTrue,
      );
    });

    test('false なら無効として通す', () {
      expect(
        announcement({
          'reactions_allowed': false,
        }).toCapsicum().reactionsAllowed,
        isFalse,
      );
    });

    test('無効でも既に付いているリアクションは落とさない', () {
      final a = announcement({
        'reactions_allowed': false,
        'reactions': [
          {'name': '👍', 'count': 2, 'me': false},
        ],
      }).toCapsicum();
      expect(a.reactions.map((r) => r.name), ['👍']);
    });

    test('copyWith（既読・リアクションの楽観更新）で無効の印を失わない', () {
      final a = announcement({'reactions_allowed': false}).toCapsicum();
      expect(a.copyWith(read: true).reactionsAllowed, isFalse);
      expect(a.copyWith(reactions: const []).reactionsAllowed, isFalse);
    });
  });
}
