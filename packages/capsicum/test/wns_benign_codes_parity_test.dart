import 'dart:io';

import 'package:capsicum/src/service/push_diagnostic_codes.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1012: Windows の「正常系」診断コードが Dart とネイティブで一致すること。
///
/// ⚠ **これまで一致を守っていたのは両側のコメントだけだった。** C++ 側の
/// テストは tag ビルドでしか回らない（`docs/tech-notes.md`「Windows ネイティブを
/// 触ったときの検証手順」）ので、`develop` に入る変更では誰も検査していない。
///
/// ずれると症状が非対称に出る:
///
/// - **Dart にだけある** … ネイティブは異常系として扱うので、単一スロットの
///   診断レコードで「異常を優先して残す」(#997) が効かない
/// - **ネイティブにだけある** … Dart が warning で上げるので、**正常運転の
///   コードが平常時の端末から毎回 warning で届く**。#997 の
///   `wns.announcement_deduped` が実際にこの形だった
///
/// ⚠ **`.cpp` を読むのは「テストできない側」を巻き込むため。** Dart 側だけの
/// 定数比較にすると、ネイティブに足したコードは何も検出できない。
void main() {
  /// `IsBenignCode` の本体から文字列リテラルを抜く。
  ///
  /// ⚠ **関数の形が変わったら落ちる**（`return code == "a" || ...` を前提に
  /// している）。落ちたら「壊れた」ではなく「検査を作り直せ」の合図。
  Set<String> nativeBenignCodes() {
    final source = File(
      'windows/runner/push_diagnostics.cpp',
    ).readAsStringSync();
    final start = source.indexOf('bool IsBenignCode(');
    expect(start, isNot(-1), reason: 'IsBenignCode が見つからない（改名した？）');
    final end = source.indexOf('\n}', start);
    expect(end, isNot(-1), reason: 'IsBenignCode の終端が見つからない');
    final body = source.substring(start, end);

    return RegExp(
      r'"([^"]+)"',
    ).allMatches(body).map((m) => m.group(1)!).toSet();
  }

  test('Dart とネイティブの benign 集合が一致する', () {
    expect(
      nativeBenignCodes(),
      wnsBenignDiagnosticCodes,
      reason:
          '片方だけに足すと、正常運転が毎回 warning で届くか、'
          '異常系の上書き防止 (#997) が効かなくなる',
    );
  });

  /// 空になっていたら、上のリテラル抽出が壊れているのに一致してしまう
  /// （両方が空集合）。抽出そのものが生きていることを別に確かめる。
  test('抽出が空振りしていない', () {
    expect(nativeBenignCodes(), isNotEmpty);
    expect(wnsBenignDiagnosticCodes, isNotEmpty);
  });

  // ⚠ **表示失敗を benign に入れない** (#957 / #978 / #997)。`*.shown` 系は
  // 表示に成功したときだけ記録されるので、失敗側が混ざると「出せていないのに
  // 正常運転」として観測から消える。
  test('表示失敗のコードは benign に入っていない', () {
    for (final code in wnsBenignDiagnosticCodes) {
      expect(code, isNot(contains('failed')), reason: '表示できなかったことは異常系として上げる');
    }
  });
}
