import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1176: Annict の記録・感想の 2 画面が `duplicate_request` を同じ扱いにする。
///
/// ⚠⚠ **押し直せる状態に戻してはいけない。**モロヘイヤの冪等性ロックは**先の要求が
/// 成功すると TTL（既定 30 秒）まで残る**ので、押し直すと**先の要求が成功していた
/// 場合に二重に記録される**。
///
/// ⚠ **2 画面はほぼ写し**（`annict_record_screen` / `annict_review_screen`）。この
/// リポジトリでは「片方だけ直る」が繰り返し起きているので、**両方が同じ形を持つこと**を
/// 機械で見る。
void main() {
  const paths = [
    'lib/src/ui/screen/annict_record_screen.dart',
    'lib/src/ui/screen/annict_review_screen.dart',
  ];

  String read(String path) => File(path).readAsStringSync();

  /// `duplicate_request` の扱いとして要るもの。⚠ コメントは落としてから見る。
  const required = [
    // 409 の code を読んでいる
    'mulukhiyaConflictCode(',
    // duplicate_request を特別扱いしている
    'MulukhiyaConflict.duplicateRequest',
    // 押し直せない形にしている
    '_duplicateSent = true',
    // 文面を共有の関数から取っている（画面ごとに書かない）
    'annictConflictMessage(',
  ];

  /// 投稿ボタンが `_duplicateSent` で無効になっているか。
  final buttonGated = RegExp(
    r'onPressed:\s*_submitting\s*\|\|\s*_duplicateSent\s*\?\s*null',
  );

  List<String> missingFrom(String source) {
    final masked = maskComments(source);
    return [
      for (final needle in required)
        if (!masked.contains(needle)) needle,
      if (!buttonGated.hasMatch(masked)) 'onPressed の _duplicateSent ガード',
    ];
  }

  group('⚠ 走査が空振りしていない', () {
    test('前提: 2 画面が実在し、どちらも 409 を扱う DioException の枝を持つ', () {
      for (final path in paths) {
        final masked = maskComments(read(path));
        expect(masked, contains('on DioException catch'), reason: path);
        expect(masked, contains('_submitting'), reason: path);
      }
    });

    test('前提: 共有の判定と文面が実在する', () {
      final util = maskComments(read('lib/src/util/mulukhiya_conflict.dart'));
      expect(util, contains('MulukhiyaConflict? mulukhiyaConflictCode('));
      expect(util, contains('String annictConflictMessage('));
      expect(util, contains("'duplicate_request' => "));
    });
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('全部揃っている合成ソースは通る', () {
      expect(missingFrom(_synthetic()), isEmpty);
    });

    test('⚠⚠ 1 つ落とすと、落としたものだけを挙げる', () {
      for (final needle in required) {
        expect(missingFrom(_synthetic(drop: needle)), [needle], reason: needle);
      }
    });

    test('⚠ ボタンのガードが無ければ挙げる', () {
      final source = _synthetic().replaceFirst(
        'onPressed: _submitting || _duplicateSent ? null : _submit,',
        'onPressed: _submitting ? null : _submit,',
      );

      expect(missingFrom(source), ['onPressed の _duplicateSent ガード']);
    });

    test('⚠ コメントでの言及は数えない', () {
      final source = _synthetic(drop: 'MulukhiyaConflict.duplicateRequest')
          .replaceFirst(
            '  void build() {',
            '  // MulukhiyaConflict.duplicateRequest もいずれ見たい\n  void build() {',
          );

      expect(missingFrom(source), ['MulukhiyaConflict.duplicateRequest']);
    });
  });

  group('⚠⚠ 歯があることを、穴を開けて確かめる', () {
    test('修正前の 2 画面（#1176 の前）は全部足りないと出る', () {
      // ⚠ SHA で固定する（`HEAD:` だと修正のコミット後に修正後を取り出してしまう）。
      // `cd5eaab7` = #1170 / #1157 の直後、#1176 に手を付ける前。
      for (final path in paths) {
        final before = Process.runSync('git', [
          'show',
          'cd5eaab7:packages/capsicum/$path',
        ], workingDirectory: '../..');
        expect(before.exitCode, 0, reason: '$path: ${before.stderr}');
        final missing = missingFrom(before.stdout as String);
        expect(missing.length, required.length + 1, reason: '$path で $missing');
      }
    });
  });

  test('⚠⚠ 2 画面とも duplicate_request を同じ形で扱っている', () {
    final offenders = <String>[];
    for (final path in paths) {
      final missing = missingFrom(read(path));
      if (missing.isNotEmpty) offenders.add('$path: ${missing.join(' / ')}');
    }
    if (offenders.isNotEmpty) {
      fail(
        'Annict の 2 画面は 409 `duplicate_request` を同じ形で扱うこと (#1176)。'
        '押し直せる状態に戻すと、先の要求が成功していた場合に二重に記録される:\n'
        '${offenders.join('\n')}',
      );
    }
  });
}

/// 判定に食わせる合成ソース。[drop] を渡すとその 1 行だけ落とす。
String _synthetic({String? drop}) {
  String line(String needle, String code) => needle == drop ? '' : code;
  return '''
class _State {
  bool _submitting = false;
  bool _duplicateSent = false;

  Future<void> _submit() async {
    try {
      await post();
    } on DioException catch (e, st) {
      ${line('mulukhiyaConflictCode(', 'final conflict = mulukhiyaConflictCode(e);')}
      ${line('MulukhiyaConflict.duplicateRequest', 'if (conflict == MulukhiyaConflict.duplicateRequest) {')}
        setState(() {
          _submitting = false;
          ${line('_duplicateSent = true', '_duplicateSent = true;')}
        });
        return;
      }
      show(${line('annictConflictMessage(', 'annictConflictMessage(conflict)')});
    }
  }

  void build() {
    TextButton(
      onPressed: _submitting || _duplicateSent ? null : _submit,
      child: const Text('投稿'),
    );
  }
}
''';
}
