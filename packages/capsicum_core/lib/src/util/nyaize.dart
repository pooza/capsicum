/// Misskey の猫語変換（nyaize）。
/// isCat ユーザーの投稿テキストに適用する。
/// 参考: misskey/packages/misskey-js/src/nyaize.ts
String nyaize(String text) {
  // ja-JP
  var result = text
      .replaceAll('な', 'にゃ')
      .replaceAll('ナ', 'ニャ')
      .replaceAll('ﾅ', 'ﾆｬ');

  // en-US
  result = result.replaceAllMapped(
    RegExp(r'(?<=n)a', caseSensitive: false),
    (m) => m.group(0) == 'A' ? 'YA' : 'ya',
  );
  result = result.replaceAllMapped(
    RegExp(r'(?<=morn)ing', caseSensitive: false),
    (m) => m.group(0) == 'ING' ? 'YAN' : 'yan',
  );
  result = result.replaceAllMapped(
    RegExp(r'(?<=every)one', caseSensitive: false),
    (m) => m.group(0) == 'ONE' ? 'NYAN' : 'nyan',
  );

  // ko-KR
  result = result.replaceAllMapped(RegExp(r'[나-낳]'), (m) {
    final code = m.group(0)!.codeUnitAt(0);
    const offset = 0xB0C4 - 0xB098; // '냐' - '나'
    return String.fromCharCode(code + offset);
  });
  result = result.replaceAllMapped(
    RegExp(r'(다$)|(다(?=\.))|(다(?= ))|(다(?=!))|(다(?=\?))', multiLine: true),
    (_) => '다냥',
  );
  result = result.replaceAllMapped(
    RegExp(r'(야(?=\?))|(야$)|(야(?= ))'),
    (_) => '냥',
  );

  return result;
}
