import 'package:flutter/services.dart';

/// ハッシュタグの TL から投稿するときの本文の組み立て (#1172)。
///
/// ⚠⚠ **簡易投稿バーの送信と投稿フォームの初期本文で同じ関数を通す。**別々に
/// 書いていたせいで、**バーから送るとタグが付くのに、バーを開いてフォームにすると
/// タグが消える**という食い違いが出ていた（2026-09-26 に発見・`docs/deck-ui-plan.md`
/// 決定済み事項 10）。
///
/// ⚠ **spec（`c%2B%2B` / `a+b`）を渡さない** (#1159)。`hashtagSpecTags` で分解した
/// タグ名の列を渡すこと。
///
/// [body] が空でも区切りの空行は入れる。**タグは常に本文の末尾**で、書き始める
/// 位置（先頭）を呼ぶ側がカーソルで示す。
String appendHashtags(String body, List<String> hashtags) {
  if (hashtags.isEmpty) return body;
  return '$body\n\n${hashtags.map((t) => '#$t').join(' ')}';
}

/// 投稿フォームを種から開くときの初期本文とカーソル位置 (#1172)。
///
/// ⚠⚠ **タグがあるときのカーソルは本文の先頭。**末尾に置くとタグの後ろから
/// 書き始めてしまい、毎回カーソルを戻すことになる（決定済み事項 10）。タグが
/// 無いときは従来どおり末尾で、簡易投稿バーから続けて書く動作を変えない。
TextEditingValue initialComposeBody(
  String? initialText,
  List<String> hashtags,
) {
  final text = appendHashtags(initialText ?? '', hashtags);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(
      offset: hashtags.isEmpty ? text.length : 0,
    ),
  );
}
