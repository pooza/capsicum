/// 「本文を書く欄」に当てる文字のスタイル (#1233)。
///
/// 投稿フォームのフォント設定（[composeFontFamilyProvider]・#892）を、投稿の
/// 本文だけでなく、同じ性格の欄にも当てる。
///
/// ## 当てる欄の線引き
///
/// **高さが伸びる欄（`maxLines: null`）＝本文を書く場所**にだけ当てる。
///
/// | 欄 | |
/// | --- | --- |
/// | 投稿の本文（`compose_screen.dart`） | 当てる |
/// | Annict の感想（`annict_review_screen.dart`） | 当てる |
/// | 投稿テンプレートの本文（`templates_manage_screen.dart`） | 当てる |
/// | プロフィールの自己紹介・チャットの入力・チャットルームの説明 | 当てない |
///
/// 下の 3 つは行数に上限のある「フォームの一項目」で、本文や感想とは書く行為の
/// 性格が違う（チャットの入力まで等幅になるのは好みが分かれる）。足りなければ
/// 後から広げられるが、逆は戻しにくい。
///
/// ⚠ **各画面で `TextStyle(fontFamily: …)` を組まない。**次に設定が増えたとき
/// （文字の大きさ等）に取り残しが出る。当てている場所は
/// `compose_text_style_guard_test.dart` が数えている。
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
