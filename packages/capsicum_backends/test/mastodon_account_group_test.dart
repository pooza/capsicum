import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// Group アクター判定 (#726)。標準 Mastodon API の `group` boolean を見る。
/// `actor_type` は REST シリアライザが公開しないため、これだけに頼ると Group
/// バッジが出ない、という回帰を防ぐ。
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

  group('MastodonAccount.toCapsicum — isGroup', () {
    test('標準の group=true で Group と判定する', () {
      final user = account({'group': true}).toCapsicum('example.com');
      expect(user.isGroup, isTrue);
    });

    test('group=false / 欠落なら Group ではない', () {
      expect(
        account({'group': false}).toCapsicum('example.com').isGroup,
        isFalse,
      );
      expect(account({}).toCapsicum('example.com').isGroup, isFalse);
    });

    test('フォーク独自の actor_type=Group もフォールバックで拾う', () {
      final user = account({'actor_type': 'Group'}).toCapsicum('example.com');
      expect(user.isGroup, isTrue);
    });

    test('通常アカウント(Person)は Group ではない', () {
      final user = account({
        'group': false,
        'actor_type': 'Person',
      }).toCapsicum('example.com');
      expect(user.isGroup, isFalse);
    });
  });
}
