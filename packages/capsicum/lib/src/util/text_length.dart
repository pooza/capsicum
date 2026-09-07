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
/// 数える。
///
/// ⚠ **にもかかわらず、本文カウンタは backend を分岐せずこれを当てている**
/// （`compose_screen` の `'$len / $maxLength'`）。以前この doc は「Mastodon の
/// 本文には当てない」と書いていたが、**実装がそうなっていない**
/// （#1035-D3）。v1.60 までは `value.text.length` だったので、当てていないの
/// ではなく**別のズレ方をしていた**だけ。
///
/// 実害は「Mastodon で URL を含む長文のカウンタが実際より多く出る」形で、
/// **正しい数え方に寄せるのは [#1034](https://github.com/pooza/capsicum/issues/1034)**。
/// ここに書いてあるのは適用範囲の事実であって、当てるなという規約ではない。
int serverTextLength(String text) => text.runes.length;

/// ⚠ **カウンタ widget はここに置かない (#1035-E4)。**`InputCounterWidgetBuilder`
/// を返す `serverLengthCounter` は Flutter に依存するので
/// `ui/util/text_length_counter.dart` にある。ここは `lib/src/util/` の他 14
/// ファイルと同じく、Flutter を import しない純関数だけを持つ。
