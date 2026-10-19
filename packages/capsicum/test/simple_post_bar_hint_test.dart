import 'package:capsicum/src/ui/widget/simple_post_bar.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1313: 簡易投稿バーのヒントに、どのサーバーへ投稿するかを出す。
void main() {
  test('サーバーを先に置く（狭い幅で後ろが切れても残る）', () {
    // サーバー名がまだ取れていないときはホスト名。
    expect(
      simplePostBarHint(postLabel: '投稿', host: 'mstdn.example'),
      'mstdn.exampleに投稿...',
    );
  });

  test('投稿ラベルはサーバーの呼び方に従う（Misskey のノートなど）', () {
    expect(
      simplePostBarHint(postLabel: 'ノート', host: 'misskey.example'),
      'misskey.exampleにノート...',
    );
  });

  test('アカウントが無いときは従来どおり', () {
    expect(simplePostBarHint(postLabel: '投稿', host: null), '投稿...');
  });
}
