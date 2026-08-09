import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// #909: 「削除してタグづけ」の再投稿を TL へ即時反映する。
///
/// モロヘイヤ (`POST /mulukhiya/api/status/tags`) はサーバー側で削除＋再投稿を
/// 行い、**SNS 本体の投稿 API のレスポンスをそのまま**返す。独自のラップは無い
/// 一方で **SNS ごとに形が違う**ので、その差をアダプターが吸収できていることを
/// 固定する。ペイロードの形は pooza/mulukhiya-toot-proxy#4491 のステージング
/// 実測が正本。
///
/// ここが壊れると、再投稿が streaming 待ちに戻る（ライブ更新 OFF やスクロール中
/// はその場で出てこない）。
const _mastodonRepost = <String, dynamic>{
  'id': '117039311685380513',
  'created_at': '2026-08-04T21:00:00.000Z',
  'content':
      '<p>本文</p><p><a href="https://mstdn.example/tags/test4491">'
      '#<span>test4491</span></a></p>',
  'visibility': 'public',
  'favourites_count': 0,
  'reblogs_count': 0,
  'replies_count': 0,
  'account': {
    'id': 'acct1',
    'username': 'me',
    'acct': 'me',
    'display_name': '私',
    'note': '',
    'avatar': 'https://mstdn.example/avatar.png',
    'header': 'https://mstdn.example/header.png',
    'followers_count': 0,
    'following_count': 0,
    'statuses_count': 1,
    'url': 'https://mstdn.example/@me',
  },
  'media_attachments': <dynamic>[],
  'mentions': <dynamic>[],
  'tags': [
    {'name': 'test4491', 'url': 'https://mstdn.example/tags/test4491'},
  ],
  'emojis': <dynamic>[],
};

const _misskeyRepost = <String, dynamic>{
  'createdNote': {
    'id': 'apiq4gr6k0',
    'createdAt': '2026-08-04T21:00:00.000Z',
    'text': '本文\n\n#test4491 #delmulin',
    'tags': ['test4491', 'delmulin'],
    'userId': 'user1',
    'user': {'id': 'user1', 'username': 'me'},
    'visibility': 'public',
    'renoteCount': 0,
    'repliesCount': 0,
  },
};

void main() {
  group('MastodonAdapter.parseRepostedPost (#909)', () {
    test('トップレベルがそのまま status の形を取り込む', () async {
      final adapter = await MastodonAdapter.create('mstdn.example');

      final post = adapter.parseRepostedPost(_mastodonRepost);

      expect(post, isNotNull);
      // 元の投稿は削除済みで、返るのは別 id の新しい投稿。
      expect(post!.id, '117039311685380513');
      expect(post.content, contains('test4491'));
      expect(post.scope, PostScope.public);
    });

    test('想定外の形では投げずに null を返す（サーバー側の再投稿は成功している）', () async {
      final adapter = await MastodonAdapter.create('mstdn.example');

      expect(adapter.parseRepostedPost(const {}), isNull);
      expect(
        adapter.parseRepostedPost(const {'error': 'Unauthorized'}),
        isNull,
      );
    });
  });

  group('MisskeyAdapter.parseRepostedPost (#909)', () {
    test('createdNote に包まれた形を取り込む', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');

      final post = adapter.parseRepostedPost(_misskeyRepost);

      expect(post, isNotNull);
      expect(post!.id, 'apiq4gr6k0');
      expect(post.content, contains('#test4491'));
    });

    test('Mastodon の形（createdNote 無し）を Misskey に渡しても null', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');

      // 取り違えても落ちないこと。SNS を跨いだ形の混同は版差より起きやすい。
      expect(adapter.parseRepostedPost(_mastodonRepost), isNull);
    });

    test('createdNote が Map でないときも null', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');

      expect(adapter.parseRepostedPost(const {'createdNote': 'x'}), isNull);
    });
  });
}
