import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 離脱時保存 (#966) が「await の後で controller を読む」形に戻っていないかの
/// 検査 (Codex P2 / PR #1013)。
///
/// `_saveDraft` は投げっぱなしで呼ばれ、**呼んだ直後に State が dispose される**
/// 経路（`PopScope` / ライフサイクル）が本命。await をまたいでから
/// `_controller.text` を読むと破棄済み ChangeNotifier に触れて落ち、`mounted` で
/// 抜ける形にすると**唯一の保存機会を捨てる**（書きかけがそのまま消える）。
///
/// 実際 PR #1013 では、取消の消去との直列化 (`await _draftClearing`) を保存値の
/// 確定より前に置いてしまい、その後の `if (!mounted) return` で離脱時保存が
/// 捨てられる形になっていた。順序そのものを固定する。
///
/// ソースを読む検査なのは、この経路が「dispose の直前に発火して、dispose の後も
/// 走り続ける」タイミングでしか現れないため。widget test では
/// `tester.pumpWidget` の破棄と保存の in-flight を狙って重ねられない。
void main() {
  test('_saveDraft は await より前に ComposeDraft を確定させる', () {
    final lines = File(
      'lib/src/ui/screen/compose_screen.dart',
    ).readAsStringSync().split('\n');

    final start = lines.indexWhere(
      (l) => l.trimRight() == '  Future<void> _saveDraft() async {',
    );
    expect(
      start,
      isNot(-1),
      reason: '_saveDraft を見つけられない。シグネチャが変わったらこのテストも直す',
    );
    final end = lines.indexWhere((l) => l == '  }', start + 1);
    expect(end, isNot(-1), reason: '_saveDraft の終端を見つけられない');
    // コメント行は落とす（この節は「await をまたぐ前に」と日本語で説明して
    // いるので、素朴に検索するとコメントを拾う）。
    final body = lines
        .sublist(start, end + 1)
        .where((l) => !l.trimLeft().startsWith('//'))
        .toList(growable: false);

    final snapshot = body.indexWhere((l) => l.contains('ComposeDraft('));
    final firstAwait = body.indexWhere((l) => l.contains('await '));
    expect(snapshot, isNot(-1), reason: '保存値の組み立てを拾えていない');
    expect(firstAwait, isNot(-1), reason: 'await を拾えていない');
    expect(
      snapshot,
      lessThan(firstAwait),
      reason:
          '_saveDraft が await の後で保存値を組んでいる。離脱時保存は dispose と'
          '競合するので、controller を読むのは await より前でなければならない',
    );
  });
}
