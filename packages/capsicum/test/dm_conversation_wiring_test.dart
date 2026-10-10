import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #1206: DM の会話の既読・削除が、投稿タイルから配線されていること。
///
/// アダプター側の口（`mastodon_conversation_test.dart`）が正しくても、タイルが
/// 呼ばなければ既読は返らず、WebUI の未読が消えないままになる。**capsicum の
/// 画面では観測できない**（他クライアントの状態の話）ので、配線が外れても
/// 気付けない。
///
/// ソースを読む検査なのは、`PostTile` を組む足場が無いため
/// （`post_tile_action_sheet_guard_test.dart` と同じ判断）。⚠ 見ているのは
/// 「在ること」だけなので、空振りで緑になる形ではない。
void main() {
  final lines = File('lib/src/ui/widget/post_tile.dart').readAsLinesSync();

  /// [signature] で始まるメソッドの本体（同じインデントの閉じ括弧まで）。
  String body(String signature) {
    final start = lines.indexWhere((l) => l.trimRight() == signature);
    expect(start, isNot(-1), reason: '$signature を見つけられない');
    final end = lines.indexWhere((l) => l == '  }', start + 1);
    expect(end, isNot(-1), reason: '$signature の終端を見つけられない');
    return lines.sublist(start, end + 1).join('\n');
  }

  test('タイルを開くとき、遷移より先に既読を返している', () {
    final src = lines.join('\n');
    final mark = src.indexOf('_markConversationRead(post);');
    expect(mark, isNot(-1), reason: 'DM を開いても既読が返らない');
    final open = src.indexOf('openPost(context, post);', mark);
    expect(open, isNot(-1));
    expect(open - mark, lessThan(120), reason: '既読の呼び出しがタイルの onTap から離れている');
  });

  test('⚠ 未読でない会話には呼ばない（開くたびに API を叩かない）', () {
    final src = body('  void _markConversationRead(Post post) {');
    expect(src, contains('!conversation.unread'));
    expect(src, contains('.markConversationRead(conversation.id)'));
  });

  test('⚠⚠ 会話の削除は deletePost を呼ばない（投稿を消してしまう）', () {
    final src = body('  void _confirmDeleteConversation(');
    expect(src, contains('.deleteConversation(conversation.id)'));
    expect(
      src,
      isNot(contains('deletePost(')),
      reason: '会話を畳む操作が、投稿そのものの削除になっている',
    );
  });

  test('アクションシートに会話の削除が、会話を引けるときだけ出る', () {
    final src = body('  void _showActionMenu(BuildContext context) {');
    expect(src, contains('.conversationOf(targetPost.id)'));
    final guard = src.indexOf('if (conversation != null)');
    expect(guard, isNot(-1), reason: 'DM 以外の投稿にも項目が出てしまう');
    expect(
      src.indexOf('_confirmDeleteConversation(', guard),
      isNot(-1),
      reason: '会話の削除の項目が無い',
    );
  });
}
