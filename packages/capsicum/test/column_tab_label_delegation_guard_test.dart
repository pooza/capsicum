import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// カラムのラベルを組む 3 か所が `deck_tabs.dart` の芯に委譲していることを見る
/// (#1420)。
///
/// ⚠⚠ **集約の再発は「壊れること」ではなく「使わなくなること」として現れる**
/// （`docs/CLAUDE.md`「ソース検査ガードの書き方」・#1083-A）。見出し・カラム編集の
/// シート・メニューバーと帯は、それぞれ `isMastodon` とリストの引き方を写して
/// 持っていて、リストを引く条件がシートだけずれていた（v2.14 のリリース前レビュー）。
/// どれかが自前の組み立てへ戻ると、芯を直してもその場所には効かない。
///
/// ⚠ `home_menu.dart` は `deckColumnMenuLabel` の本体だけを見る。同じファイルの
/// 「表示 > タブ」（デッキでないときのタブ UI）は `isMastodon` を自前で持って
/// `tabLabel` を直に呼ぶ側で、カラムではない。
void main() {
  // 値は (パス, 見る関数)。関数が null ならファイル全体を見る。
  const files = <String, (String, String?)>{
    '見出し': ('lib/src/ui/widget/deck_column_view.dart', null),
    'カラム編集のシート': ('lib/src/ui/widget/deck_columns_sheet.dart', null),
    'メニューバーと帯': (
      'lib/src/ui/widget/home_menu.dart',
      'String deckColumnMenuLabel(',
    ),
  };

  group('判定（合成ソース）', () {
    test('芯を呼んでいれば委譲している', () {
      expect(
        selfBuiltColumnLabel(
          'final label = columnTabLabelInScope(ref, column.tab);',
        ),
        isEmpty,
      );
      expect(
        selfBuiltColumnLabel(
          'final label = columnTabLabel(ref, tab, adapter, lists);',
        ),
        isEmpty,
      );
    });

    test('⚠⚠ tabLabel を直に呼んでいたら自前で組んでいる', () {
      expect(
        selfBuiltColumnLabel(
          'final label = tabLabel(ref, tab, isMastodon, adapter, lists);',
        ),
        contains('tabLabel('),
      );
    });

    test('⚠⚠ Mastodon の判定を写していたら自前で組んでいる', () {
      expect(
        selfBuiltColumnLabel('''
  final isMastodon =
      adapter != null &&
      !adapter.capabilities.supportedTimelines.contains(TimelineType.social);
'''),
        contains('supportedTimelines.contains(TimelineType.social)'),
      );
    });

    test('コメントの中にあるだけなら当てない', () {
      expect(
        selfBuiltColumnLabel('''
  // 以前は tabLabel(ref, tab, isMastodon, adapter, lists) を直に呼んでいた
  /// supportedTimelines.contains(TimelineType.social) で判定していた
  final label = columnTabLabelInScope(ref, tab);
'''),
        isEmpty,
      );
    });

    test('芯の名前の一部として出る tabLabel には当てない', () {
      expect(selfBuiltColumnLabel('columnTabLabel(ref, tab, a, l);'), isEmpty);
    });
  });

  test('芯は deck_tabs.dart にある（走査の空振りを緑にしない）', () {
    final source = maskComments(
      File('lib/src/ui/util/deck_tabs.dart').readAsStringSync(),
    );
    expect(source, contains('String columnTabLabel('));
    expect(source, contains('String columnTabLabelInScope('));
  });

  group('関数の本体の切り出し', () {
    test('見る関数の本体だけを返す', () {
      const source = '''
String other() => tabLabel(ref, t, true, a, l);
String target(int x) {
  if (x > 0) { return columnTabLabel(ref, t, a, l); }
  return '';
}
String after() => tabLabel(ref, t, true, a, l);
''';
      final body = functionBody(source, 'String target(')!;
      expect(body, contains('columnTabLabel('));
      expect(selfBuiltColumnLabel(body), isEmpty);
    });

    test('見る関数が無ければ null（走査の空振りを緑にしない）', () {
      expect(functionBody('void x() {}', 'String target('), isNull);
    });
  });

  for (final entry in files.entries) {
    test('⚠⚠ ${entry.key} はカラムのラベルを芯に委譲している', () {
      final (path, function) = entry.value;
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '走査の対象が無い（パスを確かめる）');
      final whole = file.readAsStringSync();
      final source = function == null ? whole : functionBody(whole, function);
      expect(source, isNotNull, reason: '$function が見つからない（名前を確かめる）');
      expect(
        maskComments(source!),
        matches(RegExp(r'\bcolumnTabLabel(InScope)?\(')),
        reason: '芯を呼んでいない',
      );
      expect(selfBuiltColumnLabel(source), isEmpty);
    });
  }
}

/// [head]（`String name(` の形）で始まる関数の本体（`{` から対応する `}` まで）。
/// コメントは落としてから数える。見つからなければ null。
String? functionBody(String source, String head) {
  final masked = maskComments(source);
  final start = masked.indexOf(head);
  if (start < 0) return null;
  final open = masked.indexOf('{', start);
  if (open < 0) return null;
  var depth = 0;
  for (var i = open; i < masked.length; i++) {
    final c = masked[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return masked.substring(open, i + 1);
    }
  }
  return null;
}

/// カラムのラベルを自前で組んでいる形を返す。コメントは落として見る。
List<String> selfBuiltColumnLabel(String source) {
  final masked = maskComments(source);
  return [
    if (RegExp(r'(?<![A-Za-z_])tabLabel\(').hasMatch(masked)) 'tabLabel(',
    if (masked.contains('supportedTimelines.contains(TimelineType.social)'))
      'supportedTimelines.contains(TimelineType.social)',
  ];
}
