import 'package:capsicum/src/ui/screen/profile_screen.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1363: Misskey の実績は連合しないので、他のサーバーの人には「実績」ボタンを
/// 出さない（Mastodon・他の Misskey とも）。
class _Achievements with AchievementSupport {
  @override
  Future<List<Achievement>> getAchievements(String userId) async => [];
}

User _user(String? host) => User(id: 'u1', username: 'alice', host: host);

void main() {
  const home = 'misskey.delmulin.com';
  final misskey = _Achievements();

  test('同じサーバーの人（自分を含む）には出す', () {
    expect(
      showsAchievementsButton(
        adapter: misskey,
        user: _user(home),
        accountHost: home,
      ),
      isTrue,
    );
  });

  test('host が無い相手は同じサーバーとして扱う', () {
    expect(
      showsAchievementsButton(
        adapter: misskey,
        user: _user(null),
        accountHost: home,
      ),
      isTrue,
    );
  });

  // #1372: 判定を acctOf と揃えた（isLocalHost）。旧実装は空の host と
  // 大文字小文字の違いを「別のサーバー」と読んでいた。
  test('host が空文字の相手も同じサーバーとして扱う', () {
    expect(
      showsAchievementsButton(
        adapter: misskey,
        user: _user(''),
        accountHost: home,
      ),
      isTrue,
    );
  });

  test('host の大文字小文字の違いは同じサーバーとして扱う', () {
    expect(
      showsAchievementsButton(
        adapter: misskey,
        user: _user('Misskey.Delmulin.com'),
        accountHost: home,
      ),
      isTrue,
    );
  });

  test('Mastodon の人には出さない', () {
    expect(
      showsAchievementsButton(
        adapter: misskey,
        user: _user('mstdn.b-shock.org'),
        accountHost: home,
      ),
      isFalse,
    );
  });

  test('他の Misskey の人にも出さない', () {
    expect(
      showsAchievementsButton(
        adapter: misskey,
        user: _user('misskey.io'),
        accountHost: home,
      ),
      isFalse,
    );
  });

  test('実績を持たないサーバー（Mastodon）のアカウントでは出さない', () {
    expect(
      showsAchievementsButton(
        adapter: Object(),
        user: _user(home),
        accountHost: home,
      ),
      isFalse,
    );
  });

  test('アカウントが無ければ出さない', () {
    expect(
      showsAchievementsButton(
        adapter: misskey,
        user: _user(home),
        accountHost: null,
      ),
      isFalse,
    );
  });
}
