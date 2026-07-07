import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// Mastodon 4.6 `show_media_replies` (#809)。プロフィール所有者がメディアタブに
/// 返信の添付を出すかを制御する。fromJson → toCapsicum で User まで通ることを
/// 検証する（false のときメディアタブ取得で exclude_replies を送る判定に使う）。
void main() {
  MastodonAccount account(Map<String, dynamic> overrides) =>
      MastodonAccount.fromJson({
        'id': '1',
        'username': 'capsicum',
        'acct': 'capsicum@pf.korako.me',
        'display_name': 'capsicum',
        'note': '',
        'avatar': '',
        'header': '',
        'followers_count': 0,
        'following_count': 0,
        'statuses_count': 0,
        'fields': <Map<String, dynamic>>[],
        ...overrides,
      });

  group('MastodonAccount.toCapsicum — showMediaReplies', () {
    test('show_media_replies=false を false として通す', () {
      final user = account({
        'show_media_replies': false,
      }).toCapsicum('example.com');
      expect(user.showMediaReplies, isFalse);
    });

    test('show_media_replies=true を true として通す', () {
      final user = account({
        'show_media_replies': true,
      }).toCapsicum('example.com');
      expect(user.showMediaReplies, isTrue);
    });

    test('欠落（未対応サーバー）は null（＝従来どおり返信も表示）', () {
      final user = account({}).toCapsicum('example.com');
      expect(user.showMediaReplies, isNull);
    });
  });
}
