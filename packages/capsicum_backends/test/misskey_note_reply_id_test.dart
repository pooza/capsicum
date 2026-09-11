import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1113: Misskey の返信先を `Post.inReplyToId` へ入れる。
///
/// 実機確認（2026-09-12）で、Misskey の返信を「削除して再編集」すると単独の
/// 投稿として開くことが分かった。変換で `replyId` を落としていたため、再編集が
/// 引き継ぐ元の値が最初から null だった（Mastodon は `in_reply_to_id` を入れて
/// いたので合格していた）。
void main() {
  MisskeyNote note(Map<String, dynamic> overrides) => MisskeyNote.fromJson({
    'id': 'n1',
    'createdAt': '2026-09-12T00:00:00.000Z',
    'userId': 'u1',
    'user': {'id': 'u1', 'username': 'admin'},
    'text': 'ほげ',
    'visibility': 'public',
    'renoteCount': 0,
    'repliesCount': 0,
    ...overrides,
  });

  test('replyId が inReplyToId へ入る', () {
    final post = note({'replyId': 'parent'}).toCapsicum('misskey.example');
    expect(post.inReplyToId, 'parent');
  });

  test('⚠ 指名への返信でも入る（再編集で返信が外れると送信が止まる）', () {
    final post = note({
      'replyId': 'parent',
      'visibility': 'specified',
    }).toCapsicum('misskey.example');
    expect(post.inReplyToId, 'parent');
    expect(post.scope, PostScope.direct);
  });

  test('返信でなければ null', () {
    expect(note({}).toCapsicum('misskey.example').inReplyToId, isNull);
  });
}
