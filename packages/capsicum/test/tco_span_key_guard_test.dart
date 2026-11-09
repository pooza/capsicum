import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1372: 本文の span を `ContentSpanCache` で持つ欄が t.co を解決した先を
/// 使うなら、**鍵に解決できた回数を入れ、自分で解決しに行く**こと。
///
/// ⚠ v2.10 のレビューで 2 か所の抜けが見つかった（引用カードの本文と、統合通知の
/// 本文）。鍵に回数が無いと、解決が済んでも span が作り直されず、短縮 URL の
/// ままになる。引用カードは解決しに行く処理そのものも無かった。
///
/// 判定（[tcoKeyOffenders]）:
/// - `.resolve(` の引数に `TcoResolver.getCached` があれば、第 1 引数（鍵の
///   リスト）に `_tcoResolvedCount` があること
/// - そのファイルで `TcoResolver.resolveAllIn(` を呼んでいること
///
/// あわせて、t.co の正規表現を `TcoResolver` の外に写さない（5 か所に同じ
/// 正規表現とループが写されていた）。
const _tcoResolverPath = 'lib/src/service/tco_resolver.dart';

/// [source] の中で、規約を外れている `.resolve(` の呼び出しの説明を返す。
List<String> tcoKeyOffenders(String source) {
  final masked = maskStrings(maskComments(source));
  final out = <String>[];
  var hasResolveAll = masked.contains('TcoResolver.resolveAllIn(');
  final call = RegExp(r'\.resolve\(');
  for (final m in call.allMatches(masked)) {
    final open = m.end - 1;
    final close = matchingCloseParen(masked, open);
    if (close < 0) continue;
    final args = masked.substring(open + 1, close);
    if (!args.contains('TcoResolver.getCached')) continue;
    final key = _leadingList(args);
    final line = '\n'.allMatches(masked.substring(0, m.start)).length + 1;
    if (key == null) {
      out.add('$line: 鍵がリストで書かれていない');
      continue;
    }
    if (!RegExp(r'\b_tcoResolvedCount\b').hasMatch(key)) {
      out.add('$line: 鍵に _tcoResolvedCount が無い');
    }
    if (!hasResolveAll) {
      out.add('$line: TcoResolver.resolveAllIn で解決しに行っていない');
      hasResolveAll = true; // 同じファイルで何度も言わない
    }
  }
  return out;
}

/// 引数リストの先頭が `[` ならその中身（対応する `]` まで）。違えば null。
String? _leadingList(String args) {
  final start = args.indexOf(RegExp(r'\S'));
  if (start < 0 || args[start] != '[') return null;
  var depth = 0;
  for (var i = start; i < args.length; i++) {
    if (args[i] == '[') depth++;
    if (args[i] == ']' && --depth == 0) return args.substring(start + 1, i);
  }
  return null;
}

void main() {
  final files = sourceFiles('lib', skipGenerated: true);

  test('鍵の扱いが規約どおり', () {
    final offenders = <String>[
      for (final f in files)
        for (final o in tcoKeyOffenders(f.readAsStringSync())) '${f.path}:$o',
    ];
    expect(offenders, isEmpty);
  });

  test('t.co の正規表現を TcoResolver の外に写さない', () {
    final offenders = <String>[
      for (final f in files)
        if (f.path != _tcoResolverPath &&
            maskComments(f.readAsStringSync()).contains(r't\.co'))
          f.path,
    ];
    expect(offenders, isEmpty);
  });

  group('走査が空振りしていない', () {
    // ⚠ 対象が消えると「どこにも違反が無い」で緑になる。既知の対象が
    // 列挙と判定の両方に掛かっていることを固定する。
    const known = [
      'lib/src/ui/widget/post_tile.dart',
      'lib/src/ui/widget/notification_tile.dart',
      'lib/src/ui/widget/announcement_tile.dart',
      'lib/src/ui/screen/profile_screen.dart',
      'lib/src/ui/screen/unified_notification_screen.dart',
    ];

    test('既知の対象がすべて列挙に入っている', () {
      final paths = files.map((f) => f.path).toSet();
      expect(paths, containsAll(known));
      expect(paths, contains(_tcoResolverPath));
    });

    for (final path in known) {
      test('$path に getCached を使う resolve がある', () {
        final masked = maskStrings(
          maskComments(
            files.firstWhere((f) => f.path == path).readAsStringSync(),
          ),
        );
        expect(masked, contains('TcoResolver.getCached'));
        expect(masked, contains('TcoResolver.resolveAllIn('));
        expect(masked, contains('_tcoResolvedCount'));
      });
    }
  });

  group('判定（合成ソース）', () {
    const good = '''
void initState() { TcoResolver.resolveAllIn(text, () {}); }
TextSpan f() => _spans.resolve(
  [post, content, _tcoResolvedCount],
  () => ContentRenderer(resolveUrl: (u) => TcoResolver.getCached(u)),
  (r) => r.renderMfm(content),
);
''';

    test('鍵に回数があり、解決しに行っていれば通す', () {
      expect(tcoKeyOffenders(good), isEmpty);
    });

    test('鍵に回数が無ければ落とす', () {
      final src = good.replaceFirst(', _tcoResolvedCount]', ']');
      expect(tcoKeyOffenders(src), [contains('_tcoResolvedCount が無い')]);
    });

    test('解決しに行っていなければ落とす', () {
      final src = good.replaceFirst(
        'TcoResolver.resolveAllIn(text, () {});',
        '',
      );
      expect(tcoKeyOffenders(src), [contains('resolveAllIn')]);
    });

    test('鍵がリストでなければ落とす', () {
      final src = good.replaceFirst(
        '[post, content, _tcoResolvedCount]',
        'keys',
      );
      expect(tcoKeyOffenders(src), [contains('リスト')]);
    });

    test('getCached を使わない resolve は見ない', () {
      const src = '''
TextSpan f() => _spans.resolve(
  [post, content],
  () => ContentRenderer(resolveEmoji: (s) => null),
  (r) => r.renderMfm(content),
);
''';
      expect(tcoKeyOffenders(src), isEmpty);
    });

    test('コメントの中の _tcoResolvedCount は数えない', () {
      final src = good.replaceFirst(
        ', _tcoResolvedCount]',
        ', /* _tcoResolvedCount */]',
      );
      expect(tcoKeyOffenders(src), [contains('_tcoResolvedCount が無い')]);
    });

    test('文字列の中の getCached には反応しない', () {
      const src = '''
TextSpan f() => _spans.resolve(
  [post],
  () => Text('TcoResolver.getCached'),
  (r) => r,
);
''';
      expect(tcoKeyOffenders(src), isEmpty);
    });
  });
}
