import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1340（v2.6 リリース前レビューの「参考」）: Misskey の引用の判定を上流の
/// `isQuotePacked` に揃える。
///
/// 以前は `renote != null && text != null` だけで判定していたので、本文の無い
/// 引用（CW・添付・投票だけ）がリノートとして出ていた。
void main() {
  const renoted = {
    'id': 'orig',
    'createdAt': '2026-10-27T00:00:00.000Z',
    'userId': 'u2',
    'user': {'id': 'u2', 'username': 'author'},
    'text': '元の投稿',
    'visibility': 'public',
    'renoteCount': 0,
    'repliesCount': 0,
  };

  MisskeyNote note(Map<String, dynamic> overrides) => MisskeyNote.fromJson({
    'id': 'n1',
    'createdAt': '2026-10-27T00:00:00.000Z',
    'userId': 'u1',
    'user': {'id': 'u1', 'username': 'me'},
    'text': null,
    'visibility': 'public',
    'renoteCount': 0,
    'repliesCount': 0,
    'renoteId': 'orig',
    'renote': renoted,
    ...overrides,
  });

  const file = {
    'id': 'f1',
    'name': 'a.png',
    'type': 'image/png',
    'url': 'https://misskey.example/a.png',
    'isSensitive': false,
  };

  final quotes = <String, Map<String, dynamic>>{
    '本文': {'text': 'コメント'},
    'CW だけ': {'cw': '注意'},
    '返信先だけ': {'replyId': 'parent'},
    '投票だけ': {
      'poll': {
        'choices': [
          {'text': 'a', 'votes': 0, 'isVoted': false},
        ],
        'multiple': false,
      },
    },
    '添付だけ': {
      'files': [file],
    },
  };

  for (final MapEntry(key: name, value: overrides) in quotes.entries) {
    test('$name の引用は引用として出る', () {
      final post = note(overrides).toCapsicum('misskey.example');
      expect(post.quote?.id, 'orig');
      expect(post.reblog, isNull);
    });
  }

  test('どれも無ければリノート', () {
    final post = note({}).toCapsicum('misskey.example');
    expect(post.reblog?.id, 'orig');
    expect(post.quote, isNull);
  });

  test('⚠ 添付が空の配列ならリノート（Misskey は files を [] で返す）', () {
    final post = note({'files': <Object>[]}).toCapsicum('misskey.example');
    expect(post.reblog?.id, 'orig');
    expect(post.quote, isNull);
  });

  test('リノートでなければどちらも null', () {
    final post = note({
      'text': 'ふつうの投稿',
      'renoteId': null,
      'renote': null,
    }).toCapsicum('misskey.example');
    expect(post.reblog, isNull);
    expect(post.quote, isNull);
  });
}
