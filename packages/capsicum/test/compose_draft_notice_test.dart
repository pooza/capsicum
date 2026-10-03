import 'package:capsicum/src/ui/util/compose_draft_notice.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1130: 下書きを復元したときの注記。
///
/// ⚠ **「戻せなかった」だけでなく「戻した」も伝える。**添付が実際に並ぶように
/// なったので、黙って戻すと下書きとは無関係の添付に見える。
void main() {
  group('composeDraftAttachmentNotice (#1130)', () {
    test('添付が無ければ何も言わない', () {
      expect(
        composeDraftAttachmentNotice(
          savedCount: 0,
          restoredCount: 0,
          overlaysDroppedCount: 0,
          hasText: true,
        ),
        isNull,
      );
    });

    test('⚠ 本文も添付も戻っていなければ何も言わない', () {
      expect(
        composeDraftAttachmentNotice(
          savedCount: 2,
          restoredCount: 0,
          overlaysDroppedCount: 0,
          hasText: false,
        ),
        isNull,
      );
    });

    test('全部戻せたら件数を伝える', () {
      expect(
        composeDraftAttachmentNotice(
          savedCount: 2,
          restoredCount: 2,
          overlaysDroppedCount: 0,
          hasText: true,
        ),
        '前回の入力を復元しました（添付 2 件も戻しました）',
      );
    });

    test('一部だけ戻せたら両方の件数を伝える', () {
      expect(
        composeDraftAttachmentNotice(
          savedCount: 3,
          restoredCount: 1,
          overlaysDroppedCount: 0,
          hasText: true,
        ),
        '前回の入力を復元しました（添付 1 件を戻し、2 件は戻せませんでした）',
      );
    });

    test('1 件も戻せなければ従来どおり「含まれません」', () {
      expect(
        composeDraftAttachmentNotice(
          savedCount: 2,
          restoredCount: 0,
          overlaysDroppedCount: 0,
          hasText: true,
        ),
        '前回の入力を復元しました（添付 2 件は含まれません）',
      );
    });

    test('⚠⚠ レイヤだけ落としたぶんは別に伝える（画は残るので気づけない）', () {
      expect(
        composeDraftAttachmentNotice(
          savedCount: 2,
          restoredCount: 2,
          overlaysDroppedCount: 1,
          hasText: true,
        ),
        '前回の入力を復元しました（添付 2 件も戻しました）。'
        'うち 1 件は編集前の画像が失効したため、重ねたレイヤを外しました',
      );
    });

    test('添付だけの下書き（本文が空）でも、戻したなら伝える', () {
      expect(
        composeDraftAttachmentNotice(
          savedCount: 1,
          restoredCount: 1,
          overlaysDroppedCount: 0,
          hasText: false,
        ),
        '前回の入力を復元しました（添付 1 件も戻しました）',
      );
    });
  });
}
