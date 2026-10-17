import '../../../capsicum_core.dart';

/// Misskey のワードミュートの編集 (#1290)。
///
/// 要素は **`List<String>`（キーワードの AND）か `String`（正規表現 `/pattern/flags`）**
/// （サーバーの型は `(string[] | string)[]`・#1288）。
///
/// ⚠ **Mastodon のフィルターとは畳まない**（`docs/filter-management-plan.md`
/// 決定済み事項 4）。あちらは [FilterSupport]。
abstract mixin class WordMuteSupport {
  /// ソフト（畳む）とハード（隠す）の一覧を、サーバーから取り直して返す。
  Future<({List<Object> soft, List<Object> hard})> getWordMutes();

  /// 一覧を**丸ごと置き換える**（Misskey の `i/update` は全置換）。null の段は
  /// 送らない（変えない）。
  ///
  /// 失敗はサーバーのエラーをそのまま投げる。`TOO_MANY_MUTED_WORDS`（文字数の
  /// 合計が上限を超えた）と `INVALID_REGEXP`（サーバーの RE2 で読めない）がある。
  Future<void> setWordMutes({List<Object>? soft, List<Object>? hard});
}

/// ワードミュートの一覧を、編集用のテキスト（1 行 1 条件）にする (#1290)。
///
/// 本家（`mute-block.word-mute.vue` の `render`）と同じ: キーワードの組は半角
/// スペースで繋ぎ、正規表現はそのまま。
String formatWordMuteText(List<Object> entries) => [
  for (final entry in entries)
    if (entry is String)
      entry
    else if (entry is List)
      entry.whereType<String>().join(' '),
].join('\n');

/// [parseWordMuteText] の結果。[invalidLine] が null でなければ、その行（1 始まり）
/// の正規表現が読めなかった。
typedef WordMuteParseResult = ({List<Object> entries, int? invalidLine});

/// 編集用のテキストを、ワードミュートの一覧にする (#1290)。
///
/// 本家（`mute-block.word-mute.vue` の `parseMutes`）と同じ:
/// - 行ごとに前後の空白を落とし、空行は捨てる
/// - `/pattern/flags` の形の行は正規表現。**半角スペースで分割しない**
/// - それ以外は**半角スペース**で分割してキーワードの AND にする（全角スペースは
///   区切りにしない・本家と同じ）。空の語は捨てる
///
/// ⚠ 正規表現は Dart の [RegExp] で確かめる。本家は JS、サーバーは RE2 で確かめる
/// ので完全には一致しない —— 最後に判定するのはサーバー（`INVALID_REGEXP`）。
/// ここで捕まえるのは、何行目かを示せるうちに示すため。
///
/// ⚠⚠ **[original]（読み込んだときの一覧）と同じ文面の行は、元の要素をそのまま
/// 使い、検査もしない** (#1293)。テキストの形式は往復で形が変わることがある:
/// - 1 語だけの組 `['/foo/']` は `/foo/` の行になり、読み直すと正規表現になる
/// - サーバー（RE2）は受け付けたが Dart では読めない正規表現の行があると、
///   **その段は何を直しても保存の検査で止まっていた**
///
/// 触っていない行は変わらない、を保つ。
WordMuteParseResult parseWordMuteText(
  String text, {
  List<Object> original = const [],
}) {
  final untouched = <String, Object>{};
  for (final entry in original) {
    final line = formatWordMuteText([entry]).trim();
    if (line.isNotEmpty) untouched.putIfAbsent(line, () => entry);
  }
  final entries = <Object>[];
  final lines = text.trim().split('\n');
  var lineNumber = 0;
  for (final raw in lines) {
    lineNumber++;
    final line = raw.trim();
    if (line.isEmpty) continue;
    final kept = untouched[line];
    if (kept != null) {
      entries.add(kept);
      continue;
    }
    final regexp = RegExp(r'^/(.+)/(.*)$').firstMatch(line);
    if (regexp != null) {
      if (!_isValidMuteRegex(regexp.group(1)!, regexp.group(2)!)) {
        return (entries: entries, invalidLine: lineNumber);
      }
      entries.add(line);
      continue;
    }
    final words = [
      for (final word in line.split(' '))
        if (word.isNotEmpty) word,
    ];
    if (words.isNotEmpty) entries.add(words);
  }
  return (entries: entries, invalidLine: null);
}

/// [entries] のうち、capsicum（Dart の [RegExp]）では読めない正規表現の行番号
/// （[formatWordMuteText] の 1 始まり）(#1293)。
///
/// ⚠ サーバー（RE2）と本家の Web（JS）では効くが、**capsicum の判定からは黙って
/// 外れる**行。画面で知らせるために使う。
List<int> unreadableWordMuteLines(List<Object> entries) => [
  for (var i = 0; i < entries.length; i++)
    if (entries[i] case final String line when !_isReadableMuteRegexLine(line))
      i + 1,
];

bool _isReadableMuteRegexLine(String line) {
  final regexp = RegExp(r'^/(.+)/(.*)$', dotAll: true).firstMatch(line);
  if (regexp == null) return false;
  return _isValidMuteRegex(regexp.group(1)!, regexp.group(2)!);
}

bool _isValidMuteRegex(String pattern, String flags) {
  if (flags.split('').any((flag) => !'gimsuyvd'.contains(flag))) return false;
  try {
    RegExp(
      pattern,
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
      unicode: flags.contains('u') || flags.contains('v'),
    );
    return true;
  } on FormatException {
    return false;
  }
}
