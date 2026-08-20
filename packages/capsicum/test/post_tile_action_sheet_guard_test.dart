import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #996: アクションシートの項目が dispose ガードを迂回していないかの検査。
///
/// シートは `showModalBottomSheet` で開くので **`PostTile` の dispose を生き延びる**。
/// 開いている間に背後の TL が更新されてタイルが捨てられると、項目の処理にある
/// `ref.read` / `context.push` が同期的に StateError を投げる。しかもその多くは
/// API 呼び出しより**前**にあるため、**操作が送信されないまま成功も失敗も出ずに
/// 消える**（Sentry CAPSICUM-4R）。
///
/// ⚠ **この検査が要るのは、同じ穴を 2 度開けたから。** #990 で `_showEmojiPicker`
/// 1 経路にだけ `mounted` 判定を足し、「4 経路すべてに入れた」と報告した直後に
/// 同じシートの残り 6 経路が素通りしていた。**母数はメソッド単位ではなく
/// 「シートの項目全部」**で、項目を 1 つ足すたびに人間が母数を数え直す形だと
/// 必ず取りこぼす。
///
/// ソースを読む検査なのは、シートの項目が `adapter is XxxSupport` 等の条件で
/// 出し分けられており、**全項目を同時に画面へ出す構成が作れない**ため。
/// widget test だと「そのとき出ていた項目」しか押せず、素通りする項目が
/// あっても緑のまま通る。
void main() {
  const sentinel = '_dispatchFromSheet';

  String actionMenuBody() {
    final source = File('lib/src/ui/widget/post_tile.dart').readAsStringSync();
    final lines = source.split('\n');
    final start = lines.indexWhere(
      (l) => l.trimRight() == '  void _showActionMenu(BuildContext context) {',
    );
    expect(
      start,
      isNot(-1),
      reason: '_showActionMenu を見つけられない。シグネチャが変わったらこのテストも直す',
    );
    // メソッド定義と同じインデントの閉じ括弧まで。
    final end = lines.indexWhere((l) => l == '  }', start + 1);
    expect(end, isNot(-1), reason: '_showActionMenu の終端を見つけられない');
    return lines.sublist(start, end + 1).join('\n');
  }

  test('シートの項目はすべて _sheetItem 経由で組まれている', () {
    final body = actionMenuBody();

    // 抽出が壊れて空になると検査が素通りするので、まず母数があることを確かめる。
    final items = RegExp(r'\bitem\(').allMatches(body).length;
    expect(items, greaterThan(10), reason: '項目を拾えていない。抽出が実装とずれた可能性がある');

    expect(
      body,
      isNot(contains('ListTile(')),
      reason:
          '素の ListTile が混ざっている。項目は _sheetItem（メソッド内の item ヘルパー）'
          'を通すこと。通さないと dispose 済みタイルで操作が無言で消える (#996)',
    );
    expect(
      body,
      isNot(contains('onTap:')),
      reason:
          '素の onTap が混ざっている。_sheetItem が Navigator.pop と $sentinel を'
          '面倒みるので、項目側は onSelected だけを書く (#996)',
    );
  });

  test('ListTile 以外の押せる要素にもガードが挟まっている', () {
    final body = actionMenuBody();

    // ブースト項目の subtitle にある ActionChip（公開範囲ごとのブースト）は
    // ListTile の外なので _sheetItem を通らない。手でガードを挟んである。
    final pressables = RegExp(r'onPressed:').allMatches(body).length;
    final guards = RegExp(sentinel).allMatches(body).length;
    expect(
      guards,
      greaterThanOrEqualTo(pressables),
      reason:
          '_sheetItem を通らない押せる要素が $pressables 個あるのに、$sentinel は '
          '$guards 箇所しかない。ガードの無い経路が残っている (#996)',
    );
  });
}
