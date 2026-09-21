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

  group('composeVisibleUserIds（送る宛先）', () {
    Post note({required String authorId, List<String> ids = const []}) => Post(
      id: 'n',
      postedAt: DateTime.utc(2026, 9, 21),
      author: User(id: authorId, username: 'x'),
      scope: PostScope.direct,
      visibleUserIds: ids,
    );

    // v1.66 リリース前レビュー（赤）: 返信先の宛先を足すと、外した人に届く。
    test('⚠⚠ redraft は元の投稿の宛先だけ', () {
      final result = composeVisibleUserIds(
        scope: PostScope.direct,
        redraft: note(authorId: 'me', ids: ['a', 'me']),
        me: me,
      );
      expect(result, ['a'], reason: '自分は入れない');
    });

    // ⚠⚠ 通常の返信では返信先の宛先を引き継がない（#1165 へ先送り）。宛先を
    // 見せて外せる UI が無いまま引き継ぐと、本文から消した人にも届く。
    // サーバーが返信先の投稿者を足すので、送る宛先は空でよい。
    test('⚠⚠ 通常の返信では送らない（サーバーが投稿者を足す）', () {
      expect(
        composeVisibleUserIds(scope: PostScope.direct, redraft: null, me: me),
        isEmpty,
      );
    });

    test('指名でなければ送らない', () {
      expect(
        composeVisibleUserIds(
          scope: PostScope.followersOnly,
          redraft: note(authorId: 'me', ids: ['a']),
          me: me,
        ),
        isEmpty,
      );
    });
  });
}
