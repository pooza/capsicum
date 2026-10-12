import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1197: アイコンだけのボタンには、何をするボタンかを言葉で添える。
///
/// `IconButton` はアイコンしか出さないので、ツールチップが無いと**読み上げにも
/// 長押し / ホバーにも何も出ない**。#1196 でタブ UI の AppBar 3 つを直したが、
/// 同じ抜けが 25 個あった。掃くだけでは次に足したボタンで戻るので、ここで止める。
///
/// 通すのは次のどちらか:
///
/// - `IconButton` 自身が `tooltip:` を持つ
/// - **外側が `Tooltip`**（3 階層上まで）。⚠⚠ **これを通さないと、このガードが
///   利用者を #1196 の罠へ押し込む** —— `IconButton.tooltip` は `Tooltip` を
///   ボタンの**内側**に作るので、外側の `GestureDetector.onLongPress` から長押しを
///   奪う。長押しに意味を持たせたボタンは、`Tooltip` を外側に巻くしかない
///
/// ⚠ **見ていないもの**: `PopupMenuButton` / `InkWell` + `Icon` / 自前のボタン
/// ウィジェット。同じ問題を持ちうるが、母数に入れていない。

/// [source] の中の、ツールチップを持たない `IconButton` を返す。
List<({int line, String? icon})> findTooltiplessIconButtons(String source) {
  final masked = maskStrings(maskComments(source));
  final found = <({int line, String? icon})>[];
  for (final m in RegExp(
    r'\bIconButton(?:\.(?:filled|filledTonal|outlined))?\(',
  ).allMatches(masked)) {
    final open = m.end - 1;
    final close = _matchingClose(masked, open);
    if (close < 0) continue;
    final args = masked.substring(open + 1, close);
    if (_hasTopLevelArgument(args, 'tooltip')) continue;
    if (_enclosingCalls(masked, m.start, 3).contains('Tooltip')) continue;
    found.add((
      line: '\n'.allMatches(masked.substring(0, m.start)).length + 1,
      icon: RegExp(r'Icons\.(\w+)').firstMatch(args)?.group(1),
    ));
  }
  return found;
}

int _matchingClose(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (c == '(') depth++;
    if (c == ')' && --depth == 0) return i;
  }
  return -1;
}

/// 引数リスト [args] の**いちばん外側**に `name:` があるか。入れ子の中（子の
/// ウィジェットの `tooltip:`）は数えない。
bool _hasTopLevelArgument(String args, String name) {
  var depth = 0;
  final pattern = RegExp('(?<![\\w.])$name\\s*:');
  for (var i = 0; i < args.length; i++) {
    final c = args[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (depth == 0 && pattern.matchAsPrefix(args, i) != null) return true;
  }
  return false;
}

/// [index] を囲んでいる呼び出しの名前を、内側から [levels] 個まで返す。
List<String> _enclosingCalls(String s, int index, int levels) {
  final names = <String>[];
  var depth = 0;
  for (var i = index - 1; i >= 0 && names.length < levels; i--) {
    final c = s[i];
    if (c == ')') depth++;
    if (c != '(') continue;
    if (depth > 0) {
      depth--;
      continue;
    }
    final name = RegExp(r'([\w.]+)\s*$').firstMatch(s.substring(0, i));
    names.add(name?.group(1) ?? '');
  }
  return names;
}

/// ツールチップを足さない `IconButton`。**1 件ずつ理由を書く。**
///
/// キーは `ファイル名#アイコン名`、値は件数と理由。⚠ 件数も見るので、同じ
/// ファイルに同じアイコンのボタンを黙って足すことはできない。
const _exempt = <String, ({int count, String reason})>{
  'emoji_picker.dart#clear': (
    count: 3,
    reason:
        '検索欄の suffixIcon に出る消去ボタン。入力の消去は定型で、この画面は絵文字の'
        'セルごとに Tooltip を持っているので、重ねると読みづらくなるだけ',
  ),
};

void main() {
  final files = [
    ...sourceFiles('lib/src/ui/screen'),
    ...sourceFiles('lib/src/ui/widget'),
  ];

  String nameOf(File f) => f.uri.pathSegments.last;

  test('走査が空振りしていない', () {
    expect(files.length, greaterThan(100));
    final total = files
        .map(
          (f) => RegExp(
            r'\bIconButton(?:\.\w+)?\(',
          ).allMatches(maskStrings(maskComments(f.readAsStringSync()))).length,
        )
        .fold<int>(0, (a, b) => a + b);
    expect(total, greaterThan(80), reason: 'IconButton が見つからないなら、走査が壊れている');
    // 既知の対象が母数に入っていること。
    expect(files.map(nameOf), contains('deck_screen.dart'));
    expect(files.map(nameOf), contains('emoji_picker.dart'));
  });

  group('判定', () {
    test('tooltip が無ければ当たる', () {
      final found = findTooltiplessIconButtons('''
        final a = IconButton(
          icon: const Icon(Icons.add),
          onPressed: () {},
        );
      ''');
      expect(found.single.icon, 'add');
      expect(found.single.line, 1);
    });

    test('tooltip があれば当たらない（引数の順は問わない）', () {
      expect(
        findTooltiplessIconButtons('''
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () { doSomething(1, [2]); },
            visualDensity: VisualDensity.compact,
            tooltip: '追加',
          );
        '''),
        isEmpty,
      );
    });

    test('⚠ 子のウィジェットの tooltip は数えない', () {
      final found = findTooltiplessIconButtons('''
        IconButton(
          icon: Badge(child: Foo(tooltip: 'x', child: Icon(Icons.menu))),
          onPressed: () {},
        );
      ''');
      expect(found, hasLength(1));
    });

    test('⚠⚠ 外側が Tooltip なら当たらない（長押しを持つボタンの形・#1196）', () {
      expect(
        findTooltiplessIconButtons('''
          Tooltip(
            message: '通知',
            child: GestureDetector(
              onLongPress: () {},
              child: IconButton(icon: Icon(Icons.notifications), onPressed: () {}),
            ),
          );
        '''),
        isEmpty,
      );
    });

    test('⚠ 隣に Tooltip があるだけでは通さない', () {
      final found = findTooltiplessIconButtons('''
        Row(children: [
          Tooltip(message: 'x', child: Text('a')),
          IconButton(icon: Icon(Icons.add), onPressed: () {}),
        ]);
      ''');
      expect(found, hasLength(1));
    });

    test('IconButton.filled / outlined も見る', () {
      expect(
        findTooltiplessIconButtons(
          'IconButton.filled(icon: Icon(Icons.send), onPressed: () {});',
        ),
        hasLength(1),
      );
    });

    test('⚠ コメントと文字列リテラルの中は見ない', () {
      expect(
        findTooltiplessIconButtons('''
          // IconButton(icon: Icon(Icons.add), onPressed: () {})
          final s = 'IconButton(icon: x)';
          /// `IconButton(` は tooltip を…
        '''),
        isEmpty,
      );
    });

    test('⚠ 文字列の中に tooltip: と書いてあっても、持っていることにしない', () {
      expect(
        findTooltiplessIconButtons(
          "IconButton(icon: Icon(Icons.add), onPressed: () => log('tooltip: x'));",
        ),
        hasLength(1),
      );
    });
  });

  test('ui 配下の IconButton は、ツールチップを持つ（免除は理由つきの表だけ）', () {
    final counts = <String, int>{};
    final offenders = <String>[];
    for (final file in files) {
      for (final hit in findTooltiplessIconButtons(file.readAsStringSync())) {
        final key = '${nameOf(file)}#${hit.icon}';
        counts[key] = (counts[key] ?? 0) + 1;
        if (!_exempt.containsKey(key)) {
          offenders.add('${file.path}:${hit.line} (${hit.icon})');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'ツールチップの無い IconButton がある (#1197)。`tooltip:` を足すこと。'
          '⚠ 外側に長押し（GestureDetector.onLongPress）があるなら、tooltip: では'
          'なく Tooltip を外側に巻く（#1196）',
    );
    for (final entry in _exempt.entries) {
      expect(
        counts[entry.key] ?? 0,
        entry.value.count,
        reason:
            '免除の表と実際の件数が合わない: ${entry.key}。'
            '増えたなら新しいボタンに tooltip を足す。減ったなら表を直す',
      );
    }
  });
}
