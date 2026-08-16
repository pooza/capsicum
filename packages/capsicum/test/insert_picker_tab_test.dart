import 'package:capsicum/src/ui/widget/emoji_picker.dart';
import 'package:flutter_test/flutter_test.dart';

/// #971: 投稿メニューが「カスタム絵文字…」「Unicode 絵文字…」「劇中ワード…」を
/// 別々の項目として出すために、ピッカーへ開く先のタブを渡せるようにした。
///
/// 眼目は **指定が外れても落ちないこと**。どのタブが実在するかはサーバー側の
/// 条件（カスタム絵文字対応・モロヘイヤの `word_suggest`）が決めるので、メニュー
/// の出し分けと食い違う瞬間はありうる。そこで例外を投げると「絵文字が開けない」に
/// なるため、指定は best-effort として先頭へ倒す。
void main() {
  test('実在するタブは、その位置で開く', () {
    const tabs = [
      InsertPickerTab.custom,
      InsertPickerTab.unicode,
      InsertPickerTab.word,
    ];

    expect(resolveInitialTabIndex(tabs, InsertPickerTab.custom), 0);
    expect(resolveInitialTabIndex(tabs, InsertPickerTab.unicode), 1);
    expect(resolveInitialTabIndex(tabs, InsertPickerTab.word), 2);
  });

  test('タブが欠けていても、残った並びの中の位置で開く', () {
    // モロヘイヤ無し（劇中ワードタブが出ない）サーバー。
    const tabs = [InsertPickerTab.custom, InsertPickerTab.unicode];

    expect(resolveInitialTabIndex(tabs, InsertPickerTab.unicode), 1);
  });

  test('実在しないタブの指定は先頭に倒す', () {
    const tabs = [InsertPickerTab.custom, InsertPickerTab.unicode];

    expect(resolveInitialTabIndex(tabs, InsertPickerTab.word), 0);
  });

  test('未指定は先頭', () {
    const tabs = [InsertPickerTab.custom, InsertPickerTab.unicode];

    expect(resolveInitialTabIndex(tabs, null), 0);
  });

  /// スタンプモードでカスタム絵文字非対応のバックエンドに当たった場合。
  /// `TabController(length: 0)` に対して 0 以外を渡すと assert で落ちる。
  test('タブが 1 つも無くても 0 を返す', () {
    expect(resolveInitialTabIndex(const [], InsertPickerTab.custom), 0);
    expect(resolveInitialTabIndex(const [], null), 0);
  });
}
