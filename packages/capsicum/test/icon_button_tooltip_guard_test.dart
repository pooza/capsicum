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
    final close = matchingCloseParen(masked, open);
    if (close < 0) continue;
    final args = masked.substring(open + 1, close);
    // ⚠ `tooltip: 条件 ? null : '…'` は「持っている」に数えない (#1283)。null の
    // 側ではツールチップが出ないので、外側の `Tooltip` が受けている必要がある。
    final tooltip = topLevelArgumentValue(args, 'tooltip');
    if (tooltip != null && !_canBeNull(tooltip)) continue;
    if (_enclosingCalls(masked, m.start, 3).contains('Tooltip')) continue;
    found.add((
      line: '\n'.allMatches(masked.substring(0, m.start)).length + 1,
      icon: RegExp(r'Icons\.(\w+)').firstMatch(args)?.group(1),
    ));
  }
  return found;
}

/// 引数の値 [value] が null になりうる書き方か。
///
/// 見るのは `null` そのものと、三項演算子の枝が `null` の形（`c ? null : 'x'` /
/// `c ? 'x' : null`）。⚠ 条件の側の `x == null ? 'a' : 'b'` は当てない（どちらの
/// 枝も文字列）。⚠ 変数経由（`tooltip: label` で `label` が nullable）は、型が
/// 見えないので見ていない。
bool _canBeNull(String value) =>
    value == 'null' ||
    RegExp(r'\?\s*null\s*:').hasMatch(value) ||
    RegExp(r':\s*null$').hasMatch(value);

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
  'notification_bell_button.dart#notifications_outlined': (
    count: 1,
    reason:
        '複数アカウントのときは tooltip を null にして、外側の Tooltip が受ける'
        '（長押しメニューと両立させるため・#1196）。IconButton を変数に受けて'
        'から巻いているので、囲みの走査では見えない。単体の検査は'
        ' notification_bell_button_test.dart にある',
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

    // #1283: null になりうる tooltip は「持っている」に数えない。
    test('⚠⚠ tooltip が null になりうる書き方は当たる', () {
      for (final value in [
        'null',
        "busy ? null : '送信'",
        "busy ? '送信' : null",
        "busy\n              ? null\n              : '送信'",
      ]) {
        expect(
          findTooltiplessIconButtons(
            'IconButton(icon: Icon(Icons.send), tooltip: $value, onPressed: f);',
          ),
          hasLength(1),
          reason: value,
        );
      }
    });

    test('⚠ null の側を外側の Tooltip が受けていれば当たらない', () {
      expect(
        findTooltiplessIconButtons('''
          Tooltip(
            message: '通知',
            child: IconButton(
              icon: Icon(Icons.notifications),
              tooltip: hasLongPress ? null : '通知',
              onPressed: () {},
            ),
          );
        '''),
        isEmpty,
      );
    });

    test('⚠ 条件の側の null は当てない（どちらの枝も文字列）', () {
      for (final value in [
        "label == null ? '追加' : '変更'",
        "label ?? '追加'",
        "isOn ? '解除' : '設定'",
      ]) {
        expect(
          findTooltiplessIconButtons(
            'IconButton(icon: Icon(Icons.add), tooltip: $value, onPressed: f);',
          ),
          isEmpty,
          reason: value,
        );
      }
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
