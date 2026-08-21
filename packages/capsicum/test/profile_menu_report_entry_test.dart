import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #998: プロフィールのオーバーフローメニューに通報が並んでいるかの検査。
///
/// 通報機能そのものは以前からあったが、**投稿の長押しメニューにしか導線が無く**、
/// プロフィールからは辿れなかった。ミュート / ブロックが並んでいるぶん、通報だけ
/// 無いことがかえって「実装されていない機能」に見える、というのが報告の中身。
///
/// ソースを読む検査なのは、この項目が `adapter is ReportSupport` で出し分けられて
/// いて、**全項目を同時に画面へ出す構成が作れない**ため。widget test だと
/// ReportSupport を持たない構成でも緑で通り、項目が消えたことに気付けない。
/// 判断は `post_tile_action_sheet_guard_test.dart` と同じ。
void main() {
  String source() =>
      File('lib/src/ui/screen/profile_screen.dart').readAsStringSync();

  test('相手への対処メニューに通報がミュート / ブロックと並んでいる', () {
    final src = source();
    for (final value in ['mute', 'block', 'report']) {
      expect(src, contains("value: '$value'"), reason: '$value の項目が消えている');
    }

    // 位置まで見るのは、通報だけ別の場所へ動かされると「同じ場所を探して
    // 見つからない」という報告そのものが再発するため。
    expect(
      src.indexOf("value: 'report'"),
      greaterThan(src.indexOf("value: 'block'")),
      reason: '通報がブロックから離れている。相手への対処はひとかたまりに並べる',
    );
  });

  test('通報の導線は ReportSupport を持つバックエンドでだけ出る', () {
    expect(
      source(),
      contains('is ReportSupport'),
      reason: '通報を実装していないバックエンドでも項目が出てしまう',
    );
  });

  test('通報ダイアログの TextEditingController が dispose される', () {
    final lines = source().split('\n');
    final start = lines.indexWhere(
      (l) => l.trimRight() == '  Future<void> _confirmAndReportUser() async {',
    );
    expect(
      start,
      isNot(-1),
      reason: '_confirmAndReportUser を見つけられない。シグネチャが変わったらこのテストも直す',
    );
    final end = lines.indexWhere((l) => l == '  }', start + 1);
    expect(end, isNot(-1), reason: '_confirmAndReportUser の終端を見つけられない');
    final body = lines.sublist(start, end + 1).join('\n');

    expect(
      body,
      contains('TextEditingController()'),
      reason: '抽出が実装とずれている。理由の入力欄が見当たらない',
    );
    expect(
      body,
      contains('commentController.dispose()'),
      reason: 'キャンセルで閉じたときに controller が漏れる',
    );
  });
}
