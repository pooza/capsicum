import 'package:capsicum/src/ui/util/reply_mentions.dart';
import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1161: 返信の宛先に、返信先の投稿に含まれるメンション全員を入れる
/// （Web UI と同じ動作）。
///
/// ⚠ ローカルユーザーの `User.host` には自サーバーの host が入る
/// （backend の `host ?? localHost`）ので、fixture もそれに揃える。
void main() {
  const local = 'mstdn.b-shock.org';
  const me = User(id: 'me', username: 'pooza', host: local);

  group('Mastodon: 投稿者 → mentions の順', () {
    Post post({required User author, List<PostMention> mentions = const []}) =>
        Post(
          id: 'p',
          postedAt: DateTime.utc(2026, 9, 21),
          author: author,
          content: '<p>x</p>',
          isHtml: true,
          mentions: mentions,
        );

    test('投稿者に続けてメンションを並べる', () {
      final result = buildReplyMentions(
        replyTo: post(
          author: const User(id: 'a', username: 'alice', host: local),
          mentions: const [
            PostMention(id: 'b', acct: 'bob'),
            PostMention(id: 'c', acct: 'carol@remote.example'),
          ],
        ),
        me: me,
        localHost: local,
      );
      expect(result, ['alice', 'bob', 'carol@remote.example']);
    });

    test('⚠ 自分は ID で除く（メンションにいても・投稿者でも）', () {
      final result = buildReplyMentions(
        replyTo: post(
          author: me,
          mentions: const [
            PostMention(id: 'me', acct: 'pooza'),
            PostMention(id: 'b', acct: 'bob'),
          ],
        ),
        me: me,
        localHost: local,
      );
      expect(result, ['bob']);
    });

    test('⚠ 別サーバーの同名ユーザーは自分ではない', () {
      final result = buildReplyMentions(
        replyTo: post(
          author: const User(id: 'a', username: 'alice', host: local),
          mentions: const [PostMention(id: 'x', acct: 'pooza@remote.example')],
        ),
        me: me,
        localHost: local,
      );
      expect(result, ['alice', 'pooza@remote.example']);
    });

    test('重複は落とす（投稿者が自分自身をメンションしていても）', () {
      final result = buildReplyMentions(
        replyTo: post(
          author: const User(id: 'a', username: 'alice', host: local),
          mentions: const [PostMention(id: 'a', acct: 'alice')],
        ),
        me: me,
        localHost: local,
      );
      expect(result, ['alice']);
    });

    test('リモートの投稿者は user@host', () {
      final result = buildReplyMentions(
        replyTo: post(
          author: const User(
            id: 'a',
            username: 'alice',
            host: 'remote.example',
          ),
        ),
        me: me,
        localHost: local,
      );
      expect(result, ['alice@remote.example']);
    });
  });

  group('Misskey: 投稿者 → 本文の MFM のメンション', () {
    const mkLocal = 'misskey.delmulin.com';
    const mkMe = User(id: 'me', username: 'pooza', host: mkLocal);

    Post note(String text, {User? author}) => Post(
      id: 'n',
      postedAt: DateTime.utc(2026, 9, 21),
      author: author ?? const User(id: 'a', username: 'alice', host: mkLocal),
      content: text,
    );

    test('本文のメンションを出現順に並べる', () {
      final result = buildReplyMentions(
        replyTo: note('@bob @carol@remote.example こんにちは'),
        me: mkMe,
        localHost: mkLocal,
      );
      expect(result, ['alice', 'bob', 'carol@remote.example']);
    });

    test('⚠ 投稿者がリモートなら、host の無いメンションに投稿者の host を補う', () {
      final result = buildReplyMentions(
        replyTo: note(
          '@bob おはよう',
          author: const User(
            id: 'a',
            username: 'alice',
            host: 'remote.example',
          ),
        ),
        me: mkMe,
        localHost: mkLocal,
      );
      expect(result, ['alice@remote.example', 'bob@remote.example']);
    });

    test('⚠ 自分は「同じ username かつローカル」のときだけ除く', () {
      final result = buildReplyMentions(
        replyTo: note(
          '@pooza @pooza@misskey.delmulin.com @pooza@remote.example',
        ),
        me: mkMe,
        localHost: mkLocal,
      );
      expect(result, ['alice', 'pooza@remote.example']);
    });

    test('⚠ リモートの投稿者が書いた host 無しの @pooza は、向こうのサーバーの人', () {
      final result = buildReplyMentions(
        replyTo: note(
          '@pooza',
          author: const User(
            id: 'a',
            username: 'alice',
            host: 'remote.example',
          ),
        ),
        me: mkMe,
        localHost: mkLocal,
      );
      expect(result, ['alice@remote.example', 'pooza@remote.example']);
    });

    test('自サーバーの host を明示したメンションはローカルに畳んで重複を落とす', () {
      final result = buildReplyMentions(
        replyTo: note('@bob @bob@misskey.delmulin.com @BOB'),
        me: mkMe,
        localHost: mkLocal,
      );
      expect(result, ['alice', 'bob']);
    });

    test('⚠ コードの中の @ は拾わない', () {
      final result = buildReplyMentions(
        replyTo: note('`@bob` と\n```\n@carol\n```'),
        me: mkMe,
        localHost: mkLocal,
      );
      expect(result, ['alice']);
    });

    test('本文が無ければ投稿者だけ', () {
      final result = buildReplyMentions(
        replyTo: Post(
          id: 'n',
          postedAt: DateTime.utc(2026, 9, 21),
          author: const User(id: 'a', username: 'alice', host: mkLocal),
        ),
        me: mkMe,
        localHost: mkLocal,
      );
      expect(result, ['alice']);
    });
  });

  group('extractMfmMentions', () {
    test('装飾の中のメンションも拾う', () {
      expect(extractMfmMentions(r'**@bob** $[x2 @carol@remote.example]'), [
        (username: 'bob', host: null),
        (username: 'carol', host: 'remote.example'),
      ]);
    });

    test('メールアドレスはメンションではない', () {
      expect(extractMfmMentions('mail@example.com'), isEmpty);
    });
  });

  group('inheritVisibleUserIds（Misskey の指名への返信）', () {
    Post specified({required String authorId, List<String> ids = const []}) =>
        Post(
          id: 'n',
          postedAt: DateTime.utc(2026, 9, 21),
          author: User(id: authorId, username: 'x'),
          scope: PostScope.direct,
          visibleUserIds: ids,
        );

    test('返信先の宛先と投稿者を引き継ぎ、自分を除く', () {
      expect(
        inheritVisibleUserIds(
          replyTo: specified(authorId: 'a', ids: ['me', 'b', 'c']),
          me: me,
        ),
        unorderedEquals(['a', 'b', 'c']),
      );
    });

    test('自分の指名ノートへの返信では自分を宛先に入れない', () {
      expect(
        inheritVisibleUserIds(
          replyTo: specified(authorId: 'me', ids: ['b']),
          me: me,
        ),
        ['b'],
      );
    });
  });
}
