import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1304: タイムラインの種類の表示名は `timeline_type_label.dart` の 1 本だけ。
///
/// 以前はタブの見出しとタブ管理に同じ表が 2 本あり、#1278 でリモートのみを
/// 足したときに両方へ同じ文字列を足していた。⚠ 集約の再発は「壊れること」では
/// なく「使わなくなること」として現れる（`docs/CLAUDE.md`）ので、表が他所に
/// 書かれていないことと、両画面が委譲していることの両方を見る。
void main() {
  const home = 'lib/src/ui/util/timeline_type_label.dart';
  final sources = sourceFiles('lib');

  // 表の行の形（`TimelineType.xxx: '…'`）。
  final tableRow = RegExp(r"TimelineType\.[a-zA-Z]+:\s*'");

  int rowsIn(String source) => tableRow.allMatches(maskComments(source)).length;

  test('⚠ 走査が空振りしていない: 正本には表がある', () {
    expect(sources.length, greaterThan(100));
    expect(rowsIn(File(home).readAsStringSync()), greaterThanOrEqualTo(4));
  });

  test('⚠ 判定に合成ソースを食わせる', () {
    expect(rowsIn("const a = {TimelineType.home: 'ホーム'};"), 1);
    expect(rowsIn('// TimelineType.home: \'ホーム\''), 0);
    expect(rowsIn('switch (t) { case TimelineType.home: return 1; }'), 0);
  });

  test('⚠⚠ 修正前の 2 画面は表を持っていた', () {
    for (final path in [
      'lib/src/ui/widget/home_menu.dart',
      'lib/src/ui/widget/tab_management_sheet.dart',
    ]) {
      final before = Process.runSync('git', [
        'show',
        'b5d6147f:packages/capsicum/$path',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      expect(
        rowsIn(before.stdout as String),
        greaterThanOrEqualTo(4),
        reason: path,
      );
    }
  });

  test('表は正本の 1 本だけ', () {
    final offenders = [
      for (final file in sources)
        if (file.path != home && rowsIn(file.readAsStringSync()) > 0) file.path,
    ];
    expect(offenders, isEmpty);
  });

  test('2 画面とも正本へ委譲している', () {
    for (final path in [
      'lib/src/ui/widget/home_menu.dart',
      'lib/src/ui/widget/tab_management_sheet.dart',
    ]) {
      expect(
        maskComments(File(path).readAsStringSync()),
        contains('timelineTypeLabel('),
        reason: path,
      );
    }
  });
}
