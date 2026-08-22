import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #999: ALT 編集の出し分けが**モロヘイヤのフラグ**を見ているかの検査。
///
/// ⚠ **判定そのものは純関数のテストで固定できるが、「画面が何を渡しているか」は
/// 固定できない。**実際、版判定からフラグ判定へ移した最初のコミットで
/// `canEditAttachmentDescription` の doc と定数だけ差し替わり、**呼び出し側は版
/// 判定のまま**残った（Codex P1 / PR #1004）。純関数のテストは bool を直接渡すので
/// 素通りする。
///
/// 誤る側の代償が大きいので（5.33.0 なら投稿から添付が全部外れ CW も消える、
/// 5.34.0 なら 405 で失敗する）、**入力の出どころ**をソースで固定する。
/// widget test にしないのは、メディアビューアが投稿の文脈・アダプタ・アカウントを
/// 揃えないと開けず、「出さない」側の分岐を組むのに実質フルスタックが要るため。
void main() {
  String mediaViewerSource() =>
      File('lib/src/ui/screen/media_viewer_screen.dart').readAsStringSync();

  test('mulukhiyaHandlesMediaUpdate にはフラグを渡す', () {
    expect(
      mediaViewerSource(),
      contains(
        'mulukhiyaHandlesMediaUpdate: mulukhiya?.mediaUpdateEnabled ?? false',
      ),
      reason:
          'features.media_update を名乗るサーバーでだけ導線を出す'
          '（mulukhiya#4636）',
    );
  });

  // ⚠ **版番号は判定材料にしない。**動くかどうかはモロヘイヤが刺している
  // ginseng-fediverse の版で決まり、`package.version` からは区別できない。
  test('版番号で出し分けない', () {
    final source = mediaViewerSource();

    expect(
      source,
      isNot(contains('mulukhiyaSupportsMediaUpdate')),
      reason: '版判定のヘルパーは削除済み。復活したらここで落とす',
    );
    expect(
      source,
      isNot(contains('mulukhiya?.version')),
      reason: '5.34.0 は補完するが 405 で失敗する＝版では安全性を判定できない',
    );
  });
}
