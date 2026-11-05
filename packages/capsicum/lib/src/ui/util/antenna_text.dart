/// アンテナの条件と入力欄の文字の行き来 (#1052)。
///
/// ⚠⚠ **Misskey Web（`MkAntennaEditor.vue`）と同じ規則にする。**改行で区切った
/// 行が「または」、行の中を**半角スペース**で区切った語が「かつ」。
///
/// ⚠ 全角スペースでは区切らない。Web で作った「プリキュア　実況」（全角スペースを
/// 含む 1 語）を、capsicum で開いて保存しただけで 2 語の「かつ」に変えてしまう。
library;

/// 入力欄の文字をキーワードの条件にする。空の行と空の語は落とす（サーバーも
/// 落とすので結果は同じだが、送る内容を読みやすくする）。
List<List<String>> antennaKeywordsFromText(String text) => [
  for (final line in text.split('\n'))
    if (_words(line) case final words when words.isNotEmpty) words,
];

/// キーワードの条件を入力欄の文字にする。
String antennaKeywordsToText(List<List<String>> keywords) =>
    keywords.map((group) => group.join(' ')).join('\n');

/// 入力欄の文字をユーザーの一覧にする（1 行に 1 人）。
List<String> antennaUsersFromText(String text) => [
  for (final line in text.split('\n'))
    if (line.trim() case final user when user.isNotEmpty) user,
];

/// ユーザーの一覧を入力欄の文字にする。
String antennaUsersToText(List<String> users) => users.join('\n');

List<String> _words(String line) => [
  for (final word in line.trim().split(' '))
    if (word.isNotEmpty) word,
];
