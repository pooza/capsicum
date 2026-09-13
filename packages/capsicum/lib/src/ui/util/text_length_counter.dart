import 'package:flutter/material.dart';

import '../../util/text_length.dart';

/// [serverTextLength] で数える `TextField` のカウンタ (#1027-F2)。
///
/// ⚠ **`buildCounter` に渡ってくる `currentLength` は Flutter が数えた
/// 書記素**なので使わない。[controller] から取り直す。
///
/// 表示は既定と同じ `現在 / 上限`。超過時に色を変えるのは呼び出し側の責務では
/// なく、ここで済ませる（`maxLengthEnforcement: none` で切らない運用なので、
/// **超過が見えないと気づけない**）。
///
/// ⚠ **`ui/util/` に置く (#1035-E4)。**数える純関数（[serverTextLength]）は
/// `util/` に置いたまま、Flutter に依存するこちらだけをこちらへ分けた。
/// 移した時点（#1035-E4）で `lib/src/util/` のうち **material を import して
/// いたのはここだけ**で、#1027 が `user_acct` を「ui の下にあったことが
/// provider 側の再実装の理由」として `util/` へ移したのと**向きが逆**だった。
///
/// ⚠ **既定はコードポイント ([serverTextLength])。**ALT のように両上流とも
/// コードポイントで数える欄はこれでよい。**本文と同じ上限を当てる欄**は
/// サーバーごとに規則が違う（Mastodon は書記素 + URL 23 文字）ので、
/// [count] に `postTextLength` を渡す (#1034)。
InputCounterWidgetBuilder serverLengthCounter(
  TextEditingController controller, {
  int Function(String text)? count,
}) =>
    (
      BuildContext context, {
      required int currentLength,
      required bool isFocused,
      required int? maxLength,
    }) {
      // ⚠ **上限が無い欄には出さない (#1035-E5)。**Flutter は `maxLength` が
      // null でも `buildCounter` を呼ぶので、`drive_manager_screen` の
      // 「名前の変更」「フォルダを作成」に**上限のない裸の数字**が出ていた。
      // null を返せば既定と同じ「カウンタ無し」に戻る。
      if (maxLength == null) return null;
      final length = (count ?? serverTextLength)(controller.text);
      final theme = Theme.of(context);
      return Text(
        '$length / $maxLength',
        style: theme.textTheme.bodySmall?.copyWith(
          color: length > maxLength ? theme.colorScheme.error : null,
        ),
      );
    };
