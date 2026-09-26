import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1172: 簡易投稿バーが「開く」ときと「送る」ときで、投稿の文脈が食い違わないこと。
///
/// ⚠⚠ **実際に食い違っていた。**`SimplePostBar` は送信時に `hashtags` を本文へ
/// 足す一方、`_openCompose`（フォームを開く導線）は `channelId` / `channelName`
/// だけを `extra` に載せていた。結果、**ハッシュタグの TL でバーから送るとタグが
/// 付くのに、バーを開いてフォームにするとタグが消える**。
///
/// ⚠ これは「片方だけ直せば済む」形ではない。**バーが投稿の文脈として持つ
/// フィールドが増えるたびに同じ穴が開く**ので、`_openCompose` が全部を渡して
/// いることを機械で見る。
///
/// ⚠⚠ 加えて、**本文の組み立てが 2 か所に写らないこと**も見る。バーの送信と
/// 投稿フォームの初期本文は `appendHashtags` を通す（`hashtag_body.dart`）。
void main() {
  final barPath = 'lib/src/ui/widget/simple_post_bar.dart';
  final composePath = 'lib/src/ui/screen/compose_screen.dart';
  final routerPath = 'lib/src/router.dart';

  String read(String path) => File(path).readAsStringSync();

  /// [name] の非同期メソッド本体を、`{` と対応する `}` まで切り出す。
  ///
  /// ⚠⚠ **宣言だけに当てる。**`Future<void> $name(` で探すと戻り値の型を要求
  /// できるので、`_openCompose()` のような**呼び出し**の側を掴まない
  /// （2026-09-24 に `_saveDraft` で踏んだ罠・`docs/tech-notes.md`）。
  ///
  /// ⚠ 文字列リテラル中の括弧は数えない。雑にすると空文字列を検査して緑になる。
  String bodyOf(String source, String name) {
    final head = RegExp('Future<void> $name\\([^)]*\\) async \\{');
    final m = head.firstMatch(source);
    expect(m, isNotNull, reason: '$name の宣言が見つからない。変えたならこの検査も直す');
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
    fail('$name の終端が見つからない');
  }

  /// バーが投稿の文脈として持つフィールド。`_openCompose` はこれを全部渡す。
  const contextFields = ['channelId', 'channelName', 'hashtags'];

  /// [source] の `_openCompose` が [contextFields] を全部見ているか。
  ///
  /// ⚠ コメントは落としてから見る。doc での言及を「渡している」と読まない。
  List<String> missingFrom(String source) {
    final body = bodyOf(maskComments(source), '_openCompose');
    return [
      for (final field in contextFields)
        if (!body.contains('widget.$field')) field,
    ];
  }

  group('_openCompose は投稿の文脈を全部渡す', () {
    test('⚠⚠ 実物に漏れが無い', () {
      expect(missingFrom(read(barPath)), isEmpty);
    });

    // --- 1. 走査が空振りしていないことを固定する ---

    test('前提: 切り出した本体が空でなく、`/compose` への push を含む', () {
      final body = bodyOf(maskComments(read(barPath)), '_openCompose');

      expect(body.trim(), isNotEmpty);
      expect(body, contains("'/compose'"));
      expect(
        body,
        contains('extraWithProviderScope'),
        reason:
            '⚠ 開く側のスコープを載せないと、別アカウントのカラムから開いても現在の'
            'アカウントとして投稿される (#1149)',
      );
    });

    test('前提: 検査する 3 つのフィールドが SimplePostBar に実在する', () {
      final source = maskComments(read(barPath));
      for (final field in contextFields) {
        expect(
          source,
          contains('this.$field'),
          reason: '⚠ フィールドを消したらこの検査の母数も直す',
        );
      }
    });

    test('前提: 送信側（_submitInternal）も同じ 3 つを使っている', () {
      final body = bodyOf(maskComments(read(barPath)), '_submitInternal');

      expect(body, contains('widget.hashtags'));
      expect(body, contains('widget.channelId'));
    });

    // --- 2. 判定ロジックに合成ソースを食わせる ---

    test('⚠ 全部渡している合成ソースは通る', () {
      expect(missingFrom(_synthetic(fields: contextFields)), isEmpty);
    });

    test('⚠⚠ 1 つ落とした合成ソースは、落としたものだけを挙げる', () {
      for (final dropped in contextFields) {
        final kept = [
          for (final f in contextFields)
            if (f != dropped) f,
        ];
        expect(missingFrom(_synthetic(fields: kept)), [
          dropped,
        ], reason: dropped);
      }
    });

    test('⚠ コメントや doc での言及は「渡している」と数えない', () {
      final source = _synthetic(
        fields: const ['channelId', 'channelName'],
        extraLines: const ['// widget.hashtags もいずれ渡したい'],
      );

      expect(missingFrom(source), ['hashtags']);
    });

    // --- 3. 歯があることを、穴を開けて確かめる ---

    test('⚠⚠ 修正前のソース（HEAD の 1 つ前の形）だと hashtags の漏れを検出する', () {
      // `hashtags` を渡す行だけを取り除いた形。修正前の `_openCompose` がこれ。
      final broken = read(barPath).replaceFirst(
        RegExp(
          r"if \(widget\.hashtags\.isNotEmpty\) \{\s*"
          r"extra\['hashtags'\] = widget\.hashtags;\s*\}",
        ),
        '',
      );
      expect(
        broken,
        isNot(read(barPath)),
        reason: '⚠ 置換が空振りしていたら、下の expect は「直した後のソース」を見てしまう',
      );

      expect(missingFrom(broken), ['hashtags']);
    });
  });

  group('本文の組み立ては 1 本に寄せる', () {
    test('⚠⚠ バーの送信も投稿フォームの初期本文も appendHashtags を通る', () {
      expect(maskComments(read(barPath)), contains('appendHashtags('));
      expect(
        maskComments(read(composePath)),
        contains('initialComposeBody('),
        reason: '⚠ initialComposeBody は appendHashtags を通す（hashtag_body.dart）',
      );
    });

    test('⚠ タグを自前で組み立て直していない', () {
      // 修正前は `'#$t'` の join がバー側に直接書かれていた。
      for (final path in [barPath, composePath]) {
        expect(
          maskComments(read(path)),
          isNot(contains(r"map((t) => '#$t')")),
          reason: '⚠ 組み立てを写すと、また片方だけ直る形になる ($path)',
        );
      }
    });

    test('前提: ルーターが extra の hashtags を ComposeScreen へ渡している', () {
      expect(maskComments(read(routerPath)), contains("extra?['hashtags']"));
    });
  });
}

/// 判定に食わせる合成ソース。[fields] を `_openCompose` の中で参照する。
String _synthetic({
  required List<String> fields,
  List<String> extraLines = const [],
}) {
  final lines = [
    for (final f in fields) "    extra['$f'] = widget.$f;",
    ...extraLines.map((l) => '    $l'),
  ].join('\n');
  return '''
class SimplePostBar {
  final String? channelId;
  final String? channelName;
  final List<String> hashtags;
}

class _SimplePostBarState {
  Future<void> _openCompose() async {
    final extra = <String, dynamic>{};
$lines
    await context.push<bool>(
      '/compose',
      extra: extraWithProviderScope(context, extra),
    );
  }
}
''';
}
