/// 下書きを復元したときに出す注記の文面 (#1130)。
///
/// ## なぜ関数に切り出してあるか
///
/// 文面の分岐は「何件戻せて、何件戻せなかったか」という**数の組み合わせ**で、
/// 画面を組み立てずに固定できる。`ComposeScreen` は 5000 行超で pump の足場が
/// 重いため、判断だけを外に出してここで検査する。
///
/// ## 伝える中身 (#966 → #1130)
///
/// 添付は長らく**戻らなかった**ので、注記は「含まれていない」ことだけを言えば
/// よかった。#1130 でローカル添付が戻るようになり、伝えることが 3 つになった:
///
/// 1. **戻したぶん** —— 黙って画像が並ぶと、下書きとは無関係の添付に見える
/// 2. **戻せなかったぶん** —— 一時領域が消えて失効したもの・ドライブ添付
/// 3. ⚠ **レイヤだけ落としたぶん** —— 焼き込み前の画像が失効した添付。
///    **画は残っているので気づけない**（次に編集画面を開くまで分からない）
///
/// 何も戻っていないうえに本文も無ければ、伝えることが無いので null を返す。
String? composeDraftAttachmentNotice({
  required int savedCount,
  required int restoredCount,
  required int overlaysDroppedCount,
  required bool hasText,
}) {
  if (savedCount <= 0) return null;
  if (restoredCount <= 0 && !hasText) return null;

  /// ⚠ 失効した一時ファイルと**ドライブ添付**の合計。利用者から見ればどちらも
  /// 「戻ってこなかった 1 件」なので、原因では分けない。
  final missing = savedCount - restoredCount;

  final buffer = StringBuffer('前回の入力を復元しました');
  if (restoredCount <= 0) {
    buffer.write('（添付 $missing 件は含まれません）');
  } else if (missing <= 0) {
    buffer.write('（添付 $restoredCount 件も戻しました）');
  } else {
    buffer.write('（添付 $restoredCount 件を戻し、$missing 件は戻せませんでした）');
  }
  if (overlaysDroppedCount > 0) {
    buffer.write('。うち $overlaysDroppedCount 件は編集前の画像が失効したため、重ねたレイヤを外しました');
  }
  return buffer.toString();
}
