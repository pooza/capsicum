import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1362: Mastodon はヘッダーが未設定でも `header` に既定の画像
/// （`/headers/original/missing.png`・1×1 の透明な PNG）を返す。capsicum では
/// 「ヘッダーなし」（`bannerUrl == null`）として扱う。
Map<String, dynamic> _account({
  required String header,
  String avatar = 'https://mstdn.example/avatars/original/missing.png',
}) => {
  'id': '1',
  'username': 'alice',
  'acct': 'alice',
  'display_name': '',
  'locked': false,
  'bot': false,
  'created_at': '2026-11-05T00:00:00.000Z',
  'note': '',
  'url': 'https://mstdn.example/@alice',
  'avatar': avatar,
  'avatar_static': avatar,
  'header': header,
  'header_static': header,
  'followers_count': 0,
  'following_count': 0,
  'statuses_count': 0,
  'emojis': <Object>[],
  'fields': <Object>[],
};

void main() {
  test('既定の missing.png は、ヘッダーなしにする', () {
    final user = MastodonAccount.fromJson(
      _account(header: 'https://mstdn.example/headers/original/missing.png'),
    ).toCapsicum('mstdn.example');
    expect(user.bannerUrl, isNull);
  });

  test('設定してあるヘッダーは、そのまま持つ', () {
    const url =
        'https://media.mstdn.example/accounts/headers/000/000/001/original/a.png';
    final user = MastodonAccount.fromJson(
      _account(header: url),
    ).toCapsicum('mstdn.example');
    expect(user.bannerUrl, url);
  });

  test('アバターの missing.png は既定のアバターとして表示するので、そのまま持つ', () {
    final user = MastodonAccount.fromJson(
      _account(header: 'https://mstdn.example/headers/original/missing.png'),
    ).toCapsicum('mstdn.example');
    expect(
      user.avatarUrl,
      'https://mstdn.example/avatars/original/missing.png',
    );
  });
}
