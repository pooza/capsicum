import 'package:flutter/material.dart';

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
/// ⚠ **Mastodon の本文だけは書記素で数える。**`StatusLengthValidator` が
/// `each_grapheme_cluster.size` を使っており、さらに **URL を一律 23 文字**として
/// 数える。そこは別の話なので [serverTextLength] を当てない
/// （#1027 では扱わず、別 Issue にしてある）。
int serverTextLength(String text) => text.runes.length;

/// [serverTextLength] で数える `TextField` のカウンタ (#1027-F2)。
///
/// ⚠ **`buildCounter` に渡ってくる `currentLength` は Flutter が数えた
/// 書記素**なので使わない。[controller] から取り直す。
///
/// 表示は既定と同じ `現在 / 上限`。超過時に色を変えるのは呼び出し側の責務では
/// なく、ここで済ませる（`maxLengthEnforcement: none` で切らない運用なので、
/// **超過が見えないと気づけない**）。
InputCounterWidgetBuilder serverLengthCounter(
  TextEditingController controller,
) =>
    (
      BuildContext context, {
      required int currentLength,
      required bool isFocused,
      required int? maxLength,
    }) {
      final length = serverTextLength(controller.text);
      final theme = Theme.of(context);
      final over = maxLength != null && length > maxLength;
      return Text(
        maxLength == null ? '$length' : '$length / $maxLength',
        style: theme.textTheme.bodySmall?.copyWith(
          color: over ? theme.colorScheme.error : null,
        ),
      );
    };
