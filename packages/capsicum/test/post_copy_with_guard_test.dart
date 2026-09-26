import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// `Post.copyWith` がフィールドを取りこぼさないこと (#1056)。
///
/// ⚠⚠ **doc コメントが「新フィールドの追加はここに追従する」と書いているのに、
/// 機械で見ていなかった。**#1056 で `tags` を足したとき、実際に `copyWith` から
/// 落として**enrich（猫耳・ワードミュート判定）を通った投稿だけタグが消える**
/// 状態を作った（テストを書いていて気づいた）。
///
/// ⚠ 過去にも同じ形で壊れている —— #1117-B の注記に「`filterAction` が無いと
/// Misskey adapter が `Post(...)` を手で組み直すしかなく、quote / poll / channel /
/// localOnly / language 等を軒並み捨てていた」とある。**落ちても画面が壊れず、
/// 特定の経路だけ静かに情報が消える**ので見つけにくい。
void main() {
  const path = '../capsicum_core/lib/src/model/post.dart';

  /// [name] のクラス本体を、`{` と対応する `}` まで切り出す。
  ///
  /// ⚠ 文字列リテラル中の括弧は数えない。雑にすると空文字列を検査して緑になる。
  String bodyOfClass(String source, String name) {
    final head = RegExp('class $name \\{');
    final m = head.firstMatch(source);
    expect(m, isNotNull, reason: 'class $name が見つからない');
    var depth = 0;
    String? quote;
    for (var i = m!.end - 1; i < source.length; i++) {
      final c = source[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return source.substring(m.end, i);
      }
    }
    fail('class $name の終端が見つからない');
  }

  /// `final X name;` の `name` を拾う。⚠ ジェネリクスを含む型でも取れるように、
  /// **末尾の識別子と `;`** で切る。
  List<String> fieldsIn(String classBody) => [
    for (final m in RegExp(
      r'^\s*final\s+.*?(\w+);\s*$',
      multiLine: true,
    ).allMatches(classBody))
      m.group(1)!,
  ];

  /// `copyWith` の本体で渡していないフィールドを返す。
  List<String> missingIn(String source) {
    final masked = maskComments(source);
    final classBody = bodyOfClass(masked, 'Post');
    final fields = fieldsIn(classBody);
    // `Post copyWith({...}) => Post(...)` の `Post(` 以降を見る。
    final arrow = masked.indexOf('}) => Post(');
    expect(arrow, greaterThan(0), reason: 'copyWith の形が変わった。この検査も直す');
    final call = masked.substring(arrow);
    return [
      for (final field in fields)
        if (!RegExp('(^|\\W)$field:').hasMatch(call)) field,
    ];
  }

  group('⚠ 走査が空振りしていない', () {
    test('Post のフィールドを実際に拾えている', () {
      final fields = fieldsIn(bodyOfClass(maskComments(read(path)), 'Post'));

      // ⚠ 減ったらパターンが実物の書き方から外れている。
      expect(fields.length, greaterThanOrEqualTo(40));
      // 代表的なものが取れていること（型の形が違うものを並べる）。
      expect(
        fields,
        containsAll([
          'id', // String
          'postedAt', // DateTime
          'attachments', // List<Attachment>
          'reactions', // Map<String, int>
          'reactionAcceptance', // enum?
          'mentions', // List<PostMention>
          'tags', // #1056
        ]),
      );
    });
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('全部渡している合成ソースは通る', () {
      expect(missingIn(_synthetic()), isEmpty);
    });

    test('⚠⚠ 渡し忘れたフィールドだけを挙げる', () {
      expect(missingIn(_synthetic(drop: 'tags')), ['tags']);
      expect(missingIn(_synthetic(drop: 'content')), ['content']);
    });

    test('⚠ コメントで名前を書いただけでは渡したと数えない', () {
      final source = _synthetic(
        drop: 'tags',
      ).replaceFirst('  ) => Post(', '  ) => Post(\n    // tags: tags,  いずれ渡す');

      expect(missingIn(source), ['tags']);
    });
  });

  group('⚠⚠ 歯があることを、穴を開けて確かめる', () {
    test('実物から tags の行を抜くと検出する', () {
      final broken = read(path).replaceFirst(RegExp(r'\n\s*tags: tags,'), '');
      expect(broken, isNot(read(path)), reason: '⚠ 置換が空振りしていたら意味が無い');

      expect(missingIn(broken), ['tags']);
    });
  });

  test('⚠⚠ Post.copyWith は全フィールドを渡している', () {
    final missing = missingIn(read(path));
    if (missing.isNotEmpty) {
      fail(
        'Post.copyWith が渡していないフィールド: ${missing.join(' / ')}\n'
        '⚠ 落ちると enrich（猫耳・ワードミュート判定）や ALT 編集を通った投稿だけ'
        '静かに情報が消える。copyWith に追従させること。',
      );
    }
  });
}

String read(String path) => File(path).readAsStringSync();

/// 判定に食わせる合成ソース。[drop] のフィールドだけ `copyWith` から落とす。
String _synthetic({String? drop}) {
  const fields = ['id', 'content', 'tags'];
  return '''
class Post {
  final String id;
  final String? content;
  final List<String> tags;

  const Post({required this.id, this.content, this.tags = const []});

  Post copyWith({
    String? content,
  }) => Post(
${[for (final f in fields)
    if (f != drop) '    $f: $f,'].join('\n')}
  );
}
''';
}
