import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1027-F2 / #1035-A3: サーバーと同じ単位で数え、勝手に切らない。
///
/// ## なぜ要るか
///
/// `text_length.dart` は「**切らずにサーバーと同じ単位（コードポイント）で
/// 数える**」方針を立てている。Flutter の既定はどちらも違う:
///
/// - 数え方の既定は**書記素クラスタ**。家族絵文字 👨‍👩‍👧‍👦 は書記素 1・
///   コードポイント 7 なので、**「512/512 なのにサーバーが 400」**になる
/// - `maxLengthEnforcement` の既定は**切り詰める**。上限を超えた入力が
///   **予告なく切られる**
///
/// ⚠⚠ **この 2 つは必ずセット。**片方だけだとカウンタが嘘をつく ——
/// コードポイントで数えて表示しているのに、Flutter は書記素で切っている、
/// という状態になる。
///
/// ## 何が起きていたか (#1035-A3)
///
/// `templates_manage_screen` は **compose と同じ `maxPostLengthProvider`** を
/// 上限に使いながら、**既定の書記素カウンタ + 既定の enforcement（切り詰め）**
/// のままだった。Misskey (3000) で絵文字混じりのテンプレ本文が黙って切られ、
/// compose 画面と数字も食い違っていた。
void main() {
  List<File> uiFiles() => Directory('lib/src/ui')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('探索が空振りしていない', () {
    expect(uiFiles().length, greaterThan(50));
    // ⚠ 採用箇所が 0 だと、下の 2 本は「どちらも無い」で緑になる。
    final adopters = uiFiles()
        .where(
          (f) => maskComments(
            f.readAsStringSync(),
          ).contains('serverLengthCounter'),
        )
        .toList();
    expect(
      adopters,
      isNotEmpty,
      reason: 'serverLengthCounter がどこにも無い。検査のアンカーが外れている',
    );
  });

  test('serverLengthCounter を使う欄は、切り詰めも止めている', () {
    // ⚠ **セットで使う。**コードポイントで数えて表示しながら Flutter が
    // 書記素で切ると、カウンタの数字と実際の挙動が食い違う。
    final offenders = <String>[];
    for (final file in uiFiles()) {
      final code = maskComments(file.readAsStringSync());
      if (!code.contains('serverLengthCounter')) continue;
      if (code.contains('MaxLengthEnforcement.none')) continue;
      offenders.add(file.path);
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'serverLengthCounter で数えているのに maxLengthEnforcement を'
          '既定（切り詰め）のままにしている。上限超過は赤字で見せて判断を'
          'ユーザーへ返す方針 (#1027-F2)\n${offenders.join('\n')}',
    );
  });

  test('サーバー上限を入力欄に当てている画面は serverLengthCounter を使う (#1035-A3)', () {
    // ⚠ **上限だけ揃えて数え方を揃えないのが #1035-A3 の形。**同じ
    // `maxPostLengthProvider` を上限にしながら、片方が書記素で数えていた。
    final offenders = <String>[];
    for (final file in uiFiles()) {
      final code = maskComments(file.readAsStringSync());
      if (!code.contains('maxPostLengthProvider')) continue;
      if (code.contains('serverLengthCounter')) continue;
      offenders.add(file.path);
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '投稿と同じ上限を入力欄に当てているのに、数え方が Flutter 既定'
          '（書記素）のまま。compose と数字が食い違い、超過分が黙って切られる'
          '\n${offenders.join('\n')}',
    );
  });
}
