import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1216: カラム設定シートの候補は「荷物を持たない `DeckOnlyTab`」で決まる。
///
/// ⚠⚠ **列挙ではなく構造で線を引いた**（`docs/deck-ui-plan.md` 決定済み事項
/// 9-2-2）。名前の表で選ぶと、**次に増えた種別が黙って候補から漏れる** ——
/// 実際 `SearchTab` が 2026-10-04 まで漏れていて、シートから検索カラムを
/// 置けなかった（`add` 経路を通せないので、同じアカウントで 2 本目を置く
/// 逃げ道も使えなかった）。
void main() {
  const tabTypePath = '../capsicum_core/lib/src/model/tab_type.dart';
  const sheetPath = 'lib/src/ui/widget/deck_columns_sheet.dart';

  /// この回より前の綴り（歯の確認に使う）。⚠ **`HEAD` と書かない。**
  const beforeRev = '0fb0bae3';

  String read(String path) => File(path).readAsStringSync();

  // ---- 判定ロジック（合成ソースを食わせられる形に切り出す） ----

  /// `DeckOnlyTab` の派生のうち、**引数なしで構築できる**ものの名前。
  ///
  /// ⚠ 判定材料は `const <Name>();` の実在。荷物を持つ派生は
  /// `const <Name>(this.postId);` のように引数を取るので当たらない。
  List<String> payloadFreeDeckOnlyTabs(String source) {
    final masked = maskComments(source);
    final out = <String>[];
    for (final m in RegExp(
      r'class (\w+) extends DeckOnlyTab \{',
    ).allMatches(masked)) {
      final name = m.group(1)!;
      // クラス本体を波括弧の対応で切り出す（次のクラス宣言まで読まない）。
      var depth = 0;
      var body = '';
      for (var i = m.end - 1; i < masked.length; i++) {
        if (masked[i] == '{') depth++;
        if (masked[i] == '}') {
          depth--;
          if (depth == 0) {
            body = masked.substring(m.end, i);
            break;
          }
        }
      }
      expect(body, isNotEmpty, reason: '$name の本体が切り出せない');
      if (body.contains('const $name();')) out.add(name);
    }
    return out;
  }

  /// 荷物を持つ派生の名前（上の裏返し）。
  List<String> payloadDeckOnlyTabs(String source) {
    final all = [
      for (final m in RegExp(
        r'class (\w+) extends DeckOnlyTab \{',
      ).allMatches(maskComments(source)))
        m.group(1)!,
    ];
    final free = payloadFreeDeckOnlyTabs(source).toSet();
    return [
      for (final name in all)
        if (!free.contains(name)) name,
    ];
  }

  /// `_localCandidates()` の本体を切り出す。
  ///
  /// ⚠⚠ **ファイル全体を掴まない。**掴むと「候補に実在する」が常に真になり、
  /// 検査が何も見ていない状態になる（`docs/CLAUDE.md`「走査が空振り」の型）。
  String candidatesBody(String source) {
    final m = RegExp(
      r'List<TabType> _localCandidates\(\) \{',
    ).firstMatch(source);
    expect(m, isNotNull, reason: '_localCandidates が無い。変えたならこの検査も直す');
    var depth = 0;
    for (var i = m!.end - 1; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(m.end, i);
      }
    }
    fail('_localCandidates の終端が見つからない');
  }

  /// 候補に出ていない「荷物を持たない `DeckOnlyTab`」。
  List<String> missingFromCandidates(String tabTypes, String sheet) {
    final body = maskComments(candidatesBody(sheet));
    return [
      for (final name in payloadFreeDeckOnlyTabs(tabTypes))
        if (!body.contains('const $name()')) name,
    ];
  }

  // ---- 1. 走査が空振りしていない ----

  group('⚠ 走査が空振りしていない', () {
    test('前提: `DeckOnlyTab` の派生を 10 個以上見つけている', () {
      final source = read(tabTypePath);
      final all = [
        ...payloadFreeDeckOnlyTabs(source),
        ...payloadDeckOnlyTabs(source),
      ];
      expect(all.length, greaterThanOrEqualTo(10));
      // 代表的なものが列挙に含まれること（減ったらパターンが実物から外れている）。
      expect(all, contains('SearchTab'));
      expect(all, contains('PostThreadTab'));
      expect(all, contains('ChatUserTab'));
    });

    test('⚠⚠ 前提: 荷物あり / なしの両側に実体がある', () {
      final source = read(tabTypePath);

      // ⚠ 片側が空だと「全部候補に出ている」も「全部出ていない」も自明に通る。
      expect(payloadFreeDeckOnlyTabs(source), isNotEmpty);
      expect(payloadDeckOnlyTabs(source), isNotEmpty);
      // 2026-10-04 時点の実測。増えたら 9-2-2 に判断を書き足す。
      expect(payloadFreeDeckOnlyTabs(source).toSet(), {
        'SearchTab',
        'AllNotificationsTab',
      });
      expect(payloadDeckOnlyTabs(source), contains('ProfileTab'));
    });

    test('前提: 候補の本体を切り出せていて、ファイル全体ではない', () {
      final sheet = read(sheetPath);
      final body = candidatesBody(sheet);

      expect(body, contains('NotificationsTab'));
      expect(body, contains('TimelineTab'));
      expect(body.length, lessThan(sheet.length ~/ 4));
      expect(body, isNot(contains('Widget build(')));
    });
  });

  // ---- 2. 判定に合成ソースを食わせる ----

  group('⚠ 判定に合成ソースを食わせる', () {
    const synthetic = '''
class ToolTab extends DeckOnlyTab {
  const ToolTab();
  @override
  String toKey() => 'tool';
}

class ThingTab extends DeckOnlyTab {
  final String id;
  const ThingTab(this.id);
  @override
  String toKey() => 'thing:\$id';
}
''';

    test('引数なしだけを拾う', () {
      expect(payloadFreeDeckOnlyTabs(synthetic), ['ToolTab']);
      expect(payloadDeckOnlyTabs(synthetic), ['ThingTab']);
    });

    test('⚠ コメントの中の宣言は数えない', () {
      expect(
        payloadFreeDeckOnlyTabs('''
// class GhostTab extends DeckOnlyTab {
//   const GhostTab();
// }
$synthetic
'''),
        ['ToolTab'],
      );
    });

    test('⚠⚠ 候補から漏れていたら検出する', () {
      expect(
        missingFromCandidates(
          synthetic,
          'List<TabType> _localCandidates() { return [const Other()]; }',
        ),
        ['ToolTab'],
      );
      expect(
        missingFromCandidates(
          synthetic,
          'List<TabType> _localCandidates() { return [const ToolTab()]; }',
        ),
        isEmpty,
      );
    });

    test('⚠ クラス本体の切り出しが次のクラスへ食い込んでいない', () {
      // ⚠⚠ 食い込むと `ThingTab` の本体に `const ToolTab();` が入り、
      // **荷物を持つ側まで「引数なし」と誤判定する**。
      expect(payloadFreeDeckOnlyTabs(synthetic), isNot(contains('ThingTab')));
    });
  });

  // ---- 3. 本物のソースに当てる ----

  test('⚠⚠ 荷物を持たない `DeckOnlyTab` は全部シートの候補に出ている', () {
    expect(
      missingFromCandidates(read(tabTypePath), read(sheetPath)),
      isEmpty,
      reason: '決定済み事項 9-2-2。足した種別の判断を同節へ書いてから候補に入れる',
    );
  });

  // ---- 4. 歯があることを、穴を開けて確かめる ----

  group('⚠⚠ 歯があることを、穴を開けて確かめる', () {
    String before(String path) {
      final r = Process.runSync('git', [
        'show',
        '$beforeRev:packages/capsicum/$path',
      ], workingDirectory: '../..');
      expect(r.exitCode, 0, reason: (r.stderr as String));
      return r.stdout as String;
    }

    test('#1216 の前は `SearchTab` が候補から漏れていた', () {
      expect(missingFromCandidates(read(tabTypePath), before(sheetPath)), [
        'SearchTab',
      ]);
    });

    test('⚠ `AllNotificationsTab` は当時も出ていた（退行していない側）', () {
      expect(
        maskComments(candidatesBody(before(sheetPath))),
        contains('const AllNotificationsTab()'),
      );
    });
  });
}
