import 'package:capsicum/src/service/info_bot_follow_keeper.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// #1402: 自分のサーバーのお知らせボットのフォローを保つ。

const _host = 'mstdn.b-shock.org';
const _bot = '@info@mstdn.b-shock.org';

User _user(String username, {String? host, String id = 'u1'}) =>
    User(id: id, username: username, host: host);

DioException _refusal(Object? data, {int status = 403}) {
  final options = RequestOptions(path: '/x');
  return DioException(
    requestOptions: options,
    response: Response(requestOptions: options, statusCode: status, data: data),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  group('parseAcct', () {
    test('先頭の @ はあってもなくてもよい', () {
      expect(InfoBotFollowKeeper.parseAcct(_bot), (
        username: 'info',
        host: _host,
      ));
      expect(InfoBotFollowKeeper.parseAcct('info@$_host'), (
        username: 'info',
        host: _host,
      ));
    });

    test('読めない形は null', () {
      expect(InfoBotFollowKeeper.parseAcct(null), isNull);
      expect(InfoBotFollowKeeper.parseAcct('info'), isNull);
      expect(InfoBotFollowKeeper.parseAcct('@info@'), isNull);
      expect(InfoBotFollowKeeper.parseAcct('a@b@c'), isNull);
    });
  });

  group('isOwnInfoBot', () {
    test('自分のサーバーのボット（host は空でも自サーバーでも・大文字小文字を問わない）', () {
      for (final user in [
        _user('info'),
        _user('info', host: _host),
        _user('Info', host: 'MSTDN.b-shock.org'),
      ]) {
        expect(
          InfoBotFollowKeeper.isOwnInfoBot(
            user: user,
            infoBotAcct: _bot,
            localHost: _host,
          ),
          isTrue,
          reason: '${user.username}@${user.host}',
        );
      }
    });

    test('別のサーバーの同名のアカウントはボットではない', () {
      expect(
        InfoBotFollowKeeper.isOwnInfoBot(
          user: _user('info', host: 'misskey.delmulin.com'),
          infoBotAcct: _bot,
          localHost: _host,
        ),
        isFalse,
      );
    });

    test('ボットの acct が別のサーバーを指していたら対象外', () {
      expect(
        InfoBotFollowKeeper.isOwnInfoBot(
          user: _user('info'),
          infoBotAcct: '@info@misskey.delmulin.com',
          localHost: _host,
        ),
        isFalse,
      );
    });

    test('ボットが無ければ誰も対象外', () {
      expect(
        InfoBotFollowKeeper.isOwnInfoBot(
          user: _user('info'),
          infoBotAcct: null,
          localHost: _host,
        ),
        isFalse,
      );
    });
  });

  group('ensureFollowing', () {
    late List<String> followed;
    late List<(String, String)> lookedUp;

    setUp(() {
      followed = [];
      lookedUp = [];
    });

    Future<InfoBotFollowResult> run({
      String? acct = _bot,
      String own = 'pooza',
      User? bot,
      UserRelationship rel = const UserRelationship(),
    }) => InfoBotFollowKeeper.ensureFollowing(
      infoBotAcct: acct,
      localHost: _host,
      ownUsername: own,
      lookup: (u, h) async {
        lookedUp.add((u, h));
        return bot ?? _user('info', id: 'bot');
      },
      relationship: (_) async => rel,
      follow: (id) async => followed.add(id),
    );

    test('外れていればフォローし直す', () async {
      expect(await run(), InfoBotFollowResult.followed);
      expect(lookedUp, [('info', _host)]);
      expect(followed, ['bot']);
    });

    test('フォロー中・承認待ちなら何もしない', () async {
      expect(
        await run(rel: const UserRelationship(following: true)),
        InfoBotFollowResult.following,
      );
      expect(
        await run(rel: const UserRelationship(requested: true)),
        InfoBotFollowResult.following,
      );
      expect(followed, isEmpty);
    });

    test('ブロックしている相手はフォローし直さない', () async {
      expect(
        await run(rel: const UserRelationship(blocking: true)),
        InfoBotFollowResult.blocking,
      );
      expect(followed, isEmpty);
    });

    test('ボット自身・ボットが無い・別のサーバーのボットでは API を叩かない', () async {
      expect(await run(own: 'Info'), InfoBotFollowResult.self);
      expect(await run(acct: null), InfoBotFollowResult.noBot);
      expect(
        await run(acct: '@info@misskey.delmulin.com'),
        InfoBotFollowResult.noBot,
      );
      expect(lookedUp, isEmpty);
      expect(followed, isEmpty);
    });
  });

  group('refusalMessage', () {
    test('Mastodon のフォーク（{"error": "…"}）', () {
      expect(
        InfoBotFollowKeeper.refusalMessage(
          _refusal({
            'error':
                'This user is specified by the server and cannot be unfollowed.',
          }),
        ),
        'このユーザーはサーバーが指定しているため、フォローを解除できません。',
      );
    });

    test('Misskey のフォーク（{"error": {"message", "code"}}）', () {
      expect(
        InfoBotFollowKeeper.refusalMessage(
          _refusal({
            'error': {
              'message':
                  'This user is specified by the server and cannot be blocked.',
              'code': 'CANNOT_BLOCK_AUTO_FOLLOW_USER',
            },
          }),
        ),
        'このユーザーはサーバーが指定しているため、ブロックできません。',
      );
    });

    test('ほかの 403・ほかの状態・ほかの例外では null', () {
      expect(
        InfoBotFollowKeeper.refusalMessage(_refusal({'error': 'Forbidden'})),
        isNull,
      );
      expect(
        InfoBotFollowKeeper.refusalMessage(
          _refusal({
            'error':
                'This user is specified by the server and cannot be unfollowed.',
          }, status: 422),
        ),
        isNull,
      );
      expect(InfoBotFollowKeeper.refusalMessage(StateError('x')), isNull);
    });
  });
}
