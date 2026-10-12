/// 文章を書く欄に当てる文字のスタイル (#1233)。
///
/// 投稿フォームのフォント設定（[composeFontFamilyProvider]・#892）を、投稿の
/// 本文だけでなく、文章を書く複数行の欄すべてに当てる。
///
/// ## 当てる欄の線引き
///
/// **文章を書く複数行の欄**に当てる（2026-10-12 pooza。最初は高さが伸びる欄
/// だけにしていたが、行数に上限のある欄まで広げた）。
///
/// | 欄 | |
/// | --- | --- |
/// | 投稿の本文（`compose_screen.dart`） | 当てる |
/// | Annict の感想（エピソードの記録 `annict_record_screen.dart`・作品のレビュー `annict_review_screen.dart`） | 当てる |
/// | 投稿テンプレートの本文（`templates_manage_screen.dart`） | 当てる |
/// | プロフィールの自己紹介（`profile_edit_screen.dart`） | 当てる |
/// | チャットの入力（`chat_compose_row.dart`） | 当てる |
/// | チャットルームの説明（`chat_room_edit_screen.dart`） | 当てる |
/// | 画像に重ねる文字（`image_overlay_screen.dart`） | 当てない |
/// | 1 行の欄（表示名・検索・CW など） | 当てない |
///
/// 画像に重ねる文字は文章ではなく、画像の上に描く素材。描かれる書体は別に
/// 決まるので、入力欄だけ投稿フォームのフォントにすると出来上がりと食い違う。
///
/// ⚠ **各画面で `TextStyle(fontFamily: …)` を組まない。**次に設定が増えたとき
/// （文字の大きさ等）に取り残しが出る。当てている場所は
/// `compose_text_style_guard_test.dart` が数えている。
///
/// ⚠⚠ **Annict の感想の欄は 2 つある。**最初は作品のレビューにだけ当てて、
/// 実況中に使うエピソードの記録を落とした（2026-10-12 pooza 報告）。ガードは
/// 「当てている画面」しか数えておらず、当て漏れは見ていなかった。いまは
/// **高さが伸びる欄（`maxLines: null`）を持つ画面**も数え、どれも当てている
/// ことを見る。⚠ 行数に上限のある欄は `Text` の `maxLines` と字面で区別できない
/// ので、機械では拾っていない。足すときは上の表とガードの表を直す。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/preferences_provider.dart';

/// [fontFamily] から本文の欄のスタイルを作る。空なら null（＝テーマの既定のまま）。
///
/// ⚠ **空のときに `TextStyle()` を返さない。**null なら `TextField` はテーマの
/// スタイルをそのまま使うので、設定していない利用者の見た目が変わらない。
TextStyle? composeTextStyleOf(String fontFamily) =>
    fontFamily.isEmpty ? null : TextStyle(fontFamily: fontFamily);

/// 本文を書く欄に当てるスタイル。設定が変われば作り直される（`watch`）。
TextStyle? composeTextStyle(WidgetRef ref) =>
    composeTextStyleOf(ref.watch(composeFontFamilyProvider));
