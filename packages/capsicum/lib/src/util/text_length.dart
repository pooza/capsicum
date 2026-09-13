/// サーバーが数える文字数（**Unicode コードポイント**）(#1027-F2)。
///
/// ⚠⚠ **Dart / Flutter の既定はどれもサーバーと一致しない。**
///
/// | 数え方 | 値 | 使っている場所 |
/// | --- | --- | --- |
/// | `String.length` | UTF-16 コードユニット | 旧・本文カウンタ |
/// | `String.characters.length` | 書記素クラスタ | Flutter の `maxLength` カウンタ・旧 ALT 判定 |
/// | `String.runes.length` | **コードポイント** | ここ |
///
/// サーバー側:
///
/// - **Misskey の ALT (`comment`)** … JSON Schema `maxLength: 512` + DB の
///   `varchar(512)`。どちらも**コードポイント**
/// - **Mastodon の ALT (`description`)** … ActiveRecord の `length:` 検証で、
///   Ruby の `String#length` ＝**コードポイント**
/// - **Misskey の本文** … `maxLength: 3000`（同上）
///
/// 食い違いの実害は絵文字と結合文字で出る。家族絵文字 👨‍👩‍👧‍👦 は書記素 1・
/// コードポイント 7・UTF-16 コードユニット 11。**書記素で数えると
/// 「512/512 なのにサーバーが 400」**、UTF-16 で数えると**必要以上に赤くなる**。
/// 日本語・英字はどの数え方でも同じなので、通常の入力では見た目が変わらない。
///
/// ⚠⚠ **Mastodon の本文はこの数え方と一致しない。**`StatusLengthValidator` が
/// `each_grapheme_cluster.size` を使っており、さらに **URL を一律 23 文字**として
/// 数え、**CW も同じ枠**に入れる。
///
/// ⚠⚠ **本文カウンタはここを使わない (#1034)。**`post_text_length.dart` の
/// `postTextLength` が backend ごとの規則で数える。ここは **ALT のように両上流
/// ともコードポイントで数える欄**の担当。
///
/// 経緯: v1.60 までの本文カウンタは `value.text.length`（UTF-16）で、#1027-F2 が
/// ここへ寄せ、#1035-D3 が「Mastodon には当てないと書いてあるのに当てている」
/// ことを記録し、#1034 で backend ごとに分けた。
int serverTextLength(String text) => text.runes.length;

// ⚠ **カウンタ widget はここに置かない (#1035-E4)。**`InputCounterWidgetBuilder`
// を返す `serverLengthCounter` は Flutter に依存するので
// `ui/util/text_length_counter.dart` にある。ここは Flutter を import しない
// 純関数だけを持つ（⚠ `lib/src/util/` の全ファイルがそうではない —— ファイル数を
// 書くと陳腐化するので書かない）。
