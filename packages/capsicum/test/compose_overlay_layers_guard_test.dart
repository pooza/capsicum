import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1129: 添付の差し替えでレイヤの控えを取りこぼすのを、機械で止める検査。
///
/// ## なぜ要るか
///
/// `_MediaEntry` は「投稿に使う焼き込み済みの画像 (`file`)」と「再編集のための
/// 焼き込み前の画像 + レイヤ列 (`overlaySource` / `overlayLayers`)」を**対で**持つ。
/// 対が崩れると次の 2 つが起きる:
///
/// - **`file` だけ差し替えてレイヤを残す**（トリミング等）→ 次に編集画面を開くと、
///   切ったあとの画像に**前のレイヤがもう一度乗る**（同じ文字が二重になる）
/// - **焼き込み済みの `file` を元画像として渡す** → 画に残っているレイヤの上に
///   同じレイヤが乗る
///
/// どちらも**画を見るまで気づかない**。`_MediaEntry` は `compose_screen.dart` の
/// private クラスでウィジェットテストから触れないため、ソースで見る。
///
/// ## ⚠⚠ この形の検査は、判定が壊れても緑になる
///
/// `expect(offenders, isEmpty)` は**何も見ていなくても通る**（docs/CLAUDE.md
/// 「ソース検査ガードの書き方」）。そのため、
///
/// 1. **走査が空振りしていないこと**を別テストで固定する（`_MediaEntry` の本体が
///    切り出せていること・その中には代入が**在る**こと・置き換え後の形
///    （`replaceFile` / `applyOverlay`）が実在すること）
/// 2. **判定ロジックに合成ソースを直接食わせる**（当たるべき形と、当ててはいけない
///    形＝比較・コメント・文字列リテラル）
///
/// を同じファイルに置いてある。3 点目の「実際に穴を開けて歯を確認する」は、
/// 変更前のファイル（`entry.file = croppedFile;` を持つ版）を食わせて**この検査
/// だけが落ちる**ことを 2026-09-23 に実測した。
void main() {
  final path = 'lib/src/ui/screen/compose_screen.dart';
  late String masked;

  setUpAll(() {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path が見つからない');
    // ⚠ **コメントと文字列リテラルの両方を潰す。**コメントだけだと
    // `log('entry.file = x')` のようなリテラルを違反として数える。
    masked = maskStrings(maskComments(file.readAsStringSync()));
  });

  group('_MediaEntry の差し替えは必ず窓口を通す (#1129)', () {
    test('クラスの外に `.file = ` の直代入が無い', () {
      expect(
        _assignments(_outsideMediaEntry(masked)),
        isEmpty,
        reason:
            '⚠⚠ `entry.file = ...` の直代入は、レイヤの控え '
            '(overlaySource / overlayLayers) と辻褄が合わなくなる。'
            '差し替えは `replaceFile` / `applyOverlay` を通すこと',
      );
    });

    test('再編集は焼き込み前の画像と前回のレイヤで開く', () {
      final body = _methodBody(masked, '_addOverlay');
      expect(body, isNotNull, reason: '_addOverlay の本体を切り出せていない');
      expect(
        body,
        contains('overlayBase'),
        reason: '⚠ 焼き込み済みの file を渡すと、同じレイヤが二重に乗る',
      );
      expect(
        body,
        contains('initialLayers:'),
        reason: '⚠ 渡さないと、開いた時点で前回のレイヤが消える',
      );
      expect(body, contains('applyOverlay('), reason: '結果は窓口から書き戻す');
    });
  });

  // ⚠ ここから下は「検査が動いていること」そのものの検査。
  group('⚠ 走査が空振りしていない', () {
    test('_MediaEntry の本体は切り出せていて、中身が在る', () {
      final body = _classBody(masked, '_MediaEntry');
      expect(body, isNotNull);
      // ⚠ クラスの中は `this.file` が省略された**素の代入**なので、レシーバ付きを
      // 探す [_assignments] には当たらない。切り出しが空でないことは別の目印で見る。
      expect(
        RegExp(r'(?<![.\w])file\s*=(?!=)').allMatches(body!),
        isNotEmpty,
        reason: '⚠⚠ ここが空なら、切り出しが本体ではなく空文字を返している',
      );
      expect(
        body.length,
        lessThan(masked.length ~/ 2),
        reason: 'ファイル全体を掴んでいない',
      );
    });

    // ⚠⚠ **これが本体の空振り検査。**マスク → クラス本体の切り出し → 差し引き →
    // 検出、の全段を通して「実ファイルに違反が 1 つあれば落ちる」ことを見る。
    // 途中のどこかが黙って空を返していると、ここで気づく。
    test('実ファイルへ違反を 1 つ混ぜると検出できる', () {
      const injected = 'void _injected() { entry.file = x; }\n  ';
      final marker = 'Future<void> _addOverlay';
      expect(masked, contains(marker), reason: '差し込み先が実在する');
      final hole = masked.replaceFirst(marker, injected + marker);
      // ⚠ **件数の差で見る。**「ちょうど 1 件」にすると、実ファイルに違反が在る
      // 状態（＝上の検査が既に赤の状態）でこちらまで道連れで落ちて、原因が
      // 読みにくくなる。見たいのは「1 件増えたことを検出できるか」だけ。
      final before = _assignments(_outsideMediaEntry(masked)).length;
      expect(
        _assignments(_outsideMediaEntry(hole)),
        hasLength(before + 1),
        reason: '⚠⚠ 増えないなら、検査は何も見ていない',
      );
    });

    test('置き換え後の形（窓口）が実在し、外から呼ばれている', () {
      final body = _classBody(masked, '_MediaEntry')!;
      expect(body, contains('void replaceFile('));
      expect(body, contains('void applyOverlay('));
      expect(body, contains('XFile? get overlayBase'));

      final outside = masked.replaceAll(body, '');
      expect(outside, contains('.replaceFile('), reason: 'トリミングが通る窓口');
      expect(outside, contains('.applyOverlay('), reason: 'レイヤ編集が通る窓口');
    });

    test('_addOverlay の本体は切り出せていて、ファイル全体ではない', () {
      final body = _methodBody(masked, '_addOverlay');
      expect(body, isNotNull);
      expect(body!.length, lessThan(masked.length ~/ 4));
      expect(body, contains('ImageOverlayScreen('), reason: '編集画面を開く本体を掴んでいる');
    });
  });

  group('⚠ 判定ロジックに合成ソースを食わせる', () {
    test('当てるべき形', () {
      expect(_assignments('entry.file = next;'), hasLength(1));
      expect(_assignments('  e.file   =  x;'), hasLength(1));
      expect(_assignments('setState(() => entry.file = next);'), hasLength(1));
    });

    test('当ててはいけない形', () {
      // 比較。`=` が 1 文字多いだけで意味が反対。
      expect(_assignments('if (entry.file == null) return;'), isEmpty);
      expect(_assignments('entry.file != null'), isEmpty);
      // ⚠ 別のフィールド。`file` の前方一致で拾うと `driveFile` に当たる。
      expect(_assignments('entry.driveFile = x;'), isEmpty);
      expect(_assignments('entry.overlayLayers = const [];'), isEmpty);
      // コメントと文字列リテラルは前処理で落ちる前提。
      // ⚠ **`maskComments` だけでは足りない。**あれはリテラルの中の `//` を
      // コメントと誤読しないための処理で、リテラル自体は残る。
      expect(
        _assignments(maskStrings(maskComments('// entry.file = next;'))),
        isEmpty,
      );
      expect(
        _assignments(maskStrings(maskComments("log('entry.file = next;');"))),
        isEmpty,
      );
    });
  });
}

/// `_MediaEntry` の本体を空白へ潰したソース。クラスの中の代入は窓口の実装なので
/// 違反ではない。⚠ **長さを保って潰す**（削ると差し込み位置の検証がずれる）。
String _outsideMediaEntry(String masked) {
  final body = _classBody(masked, '_MediaEntry');
  if (body == null) {
    throw StateError('_MediaEntry の本体を切り出せていない');
  }
  final start = masked.indexOf(body);
  return masked.replaceRange(start, start + body.length, ' ' * body.length);
}

/// レシーバ付きの `.file = `（比較ではない代入）の一覧。
///
/// ⚠ **`.` を必須にする。**外さないと `final file = entry.file!;` のような
/// **ローカル変数の宣言**まで拾って、直す先が無い違反を報告する（初版で実際に
/// 踏んだ）。`driveFile` に当たらないのも `.` を見ているおかげ。
/// ⚠ `==` を除くため、`=` の次が `=` でないことまで見る。
List<String> _assignments(String source) => RegExp(
  r'\.file\s*=(?!=)',
).allMatches(source).map((m) => m.group(0)!).toList();

/// `class <name>` の本体（`{` 〜 対応する `}`）。見つからなければ null。
String? _classBody(String masked, String name) =>
    _bodyAfter(masked, RegExp('class\\s+$name\\b'));

/// メソッド `<name>(` の本体。見つからなければ null。
String? _methodBody(String masked, String name) =>
    _bodyAfter(masked, RegExp('$name\\s*\\('));

/// [pattern] の直後にある最初の `{` から、対応する `}` までを返す。
///
/// ⚠ **コメントを落とした後のソースに食わせること。**本文の `{` `}` を数えるので、
/// 日本語コメントの中の括弧を読むと本体がそこで終わったことになる
/// （`dart_source.dart` の doc を参照）。
String? _bodyAfter(String masked, Pattern pattern) {
  final match = pattern.allMatches(masked).firstOrNull;
  if (match == null) return null;
  final open = masked.indexOf('{', match.end);
  if (open < 0) return null;
  var depth = 0;
  for (var i = open; i < masked.length; i++) {
    if (masked[i] == '{') depth++;
    if (masked[i] == '}') {
      depth--;
      if (depth == 0) return masked.substring(open, i + 1);
    }
  }
  return null;
}
