import 'package:flutter/material.dart';

/// shortcode 候補 `:foo:` (#609)。前後を ASCII の \w でガードして `12:34` や
/// `foo:bar:baz` の中切れを拾わない。Mastodon の shortcode は `[a-zA-Z0-9_]` の
/// みで構成される (custom_emojis API の制約に追従)。
final RegExp shortcodePattern = RegExp(r'(?<![\w]):([a-zA-Z0-9_]+):(?![\w])');

/// 自サーバー custom_emojis に未登録の shortcode を赤波下線で装飾する
/// TextEditingController (#609)。Mastodon の shortcode は投稿先サーバーに
/// 未登録だと raw text として表示される (「絵文字失敗芸」)。プレビュー押下を
/// 要求せず compose 中に気付ける UI を提供する。
///
/// 利用側は `setUnknownShortcodes` で「現在のテキスト中で警告対象とすべき
/// shortcode 集合」を渡す。判定 (custom_emojis 一覧との突き合わせ) は呼び
/// 出し側の責務で、本コントローラは装飾だけを担う。
class ShortcodeWarningController extends TextEditingController {
  Set<String> _unknownShortcodes = const {};

  void setUnknownShortcodes(Set<String> codes) {
    if (_unknownShortcodes.length == codes.length &&
        _unknownShortcodes.containsAll(codes)) {
      return;
    }
    _unknownShortcodes = codes;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // IME 変換中は composing 下線が出るので警告装飾を重ねない。super 実装の
    // composing ハイライトを優先する。確定後に呼び出し側が再評価して警告
    // 装飾が乗る。
    if (_unknownShortcodes.isEmpty ||
        (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final text = this.text;
    final warningStyle = (style ?? const TextStyle()).copyWith(
      decoration: TextDecoration.underline,
      decorationColor: Colors.red,
      decorationStyle: TextDecorationStyle.wavy,
    );
    final children = <TextSpan>[];
    var lastEnd = 0;
    for (final match in shortcodePattern.allMatches(text)) {
      final code = match.group(1)!;
      if (!_unknownShortcodes.contains(code)) continue;
      if (match.start > lastEnd) {
        children.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      children.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: warningStyle,
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      children.add(TextSpan(text: text.substring(lastEnd)));
    }
    return TextSpan(style: style, children: children);
  }
}
