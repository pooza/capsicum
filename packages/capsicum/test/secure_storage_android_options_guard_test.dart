import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1120: `FlutterSecureStorage(...)` を作るときは、必ず
/// `aOptions: kSecureStorageAndroidOptions` を渡す。
///
/// ## なぜ要るか
///
/// `flutter_secure_storage` 10 の `AndroidOptions` は既定値のままだと
/// **9.x のデータの移行に失敗したとき全消去する**（`resetOnError` の既定が
/// true に変わった）。既定値を使う `FlutterSecureStorage(...)` が 1 つでも
/// 増えると、そこから移行が走った瞬間に**全ユーザーが黙ってログアウトする**
/// 経路になる。
///
/// ⚠ **店ごとに違う値にもしない。**Android の 3 つの店は名前空間無しの同じ
/// 保存ファイルを共有しているので、ある店の移行が他の店のデータにも効く。
///
/// ## 何を違反とするか
///
/// lib の `FlutterSecureStorage(` の呼び出しで、引数に
/// `aOptions: kSecureStorageAndroidOptions` が無いもの。⚠ **型注釈
/// （`FlutterSecureStorage? storage`）は呼び出しではない**ので見ない。

/// `FlutterSecureStorage(` の呼び出しごとに、括弧の中身を返す。
List<String> secureStorageConstructions(String code) {
  final result = <String>[];
  for (final m in RegExp(r'FlutterSecureStorage\s*\(').allMatches(code)) {
    var depth = 1;
    var i = m.end;
    while (i < code.length && depth > 0) {
      final c = code[i];
      if (c == '(') depth++;
      if (c == ')') depth--;
      i++;
    }
    result.add(code.substring(m.end, i - 1));
  }
  return result;
}

/// 共通の Android options を渡していない呼び出しの数。
int constructionsWithoutSharedAndroidOptions(String code) =>
    secureStorageConstructions(code)
        .where(
          (args) => !RegExp(
            r'aOptions\s*:\s*kSecureStorageAndroidOptions\b',
          ).hasMatch(args),
        )
        .length;

void main() {
  String normalize(String source) => maskStrings(maskComments(source));

  List<File> libFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('探索が空振りしていない', () {
    // ⚠ 3 つの店がそれぞれ 1 つずつ作っている。ここが減ると下の検査は
    // 「呼び出しが無い」で緑になる。
    final total = libFiles()
        .map((f) => secureStorageConstructions(normalize(f.readAsStringSync())))
        .fold<int>(0, (sum, c) => sum + c.length);
    expect(total, greaterThanOrEqualTo(3));

    // 共通の値の定義が実在し、既定値のままではないこと。
    final gate = normalize(
      File('lib/src/service/secure_storage_gate.dart').readAsStringSync(),
    );
    expect(gate, contains('const kSecureStorageAndroidOptions'));
    expect(gate, contains('resetOnError: false'));
    expect(gate, contains('migrateWithBackup: true'));
  });

  test('lib の FlutterSecureStorage(...) は全部、共通の Android options を渡す', () {
    final offenders = <String>[];
    for (final file in libFiles()) {
      final n = constructionsWithoutSharedAndroidOptions(
        normalize(file.readAsStringSync()),
      );
      if (n > 0) offenders.add('${file.path}: $n 箇所');
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'aOptions: kSecureStorageAndroidOptions を渡していない '
          'FlutterSecureStorage がある (#1120)。既定値のままだと、9.x のデータの'
          '移行に失敗したとき全消去される\n${offenders.join('\n')}',
    );
  });

  group('走査に歯がある', () {
    test('合成したソースで当たるべき形に当たる', () {
      // 何も渡さない。
      expect(
        constructionsWithoutSharedAndroidOptions(
          'const s = FlutterSecureStorage();',
        ),
        1,
      );
      // Apple の options だけ渡す（修正前の 3 店の形）。
      expect(
        constructionsWithoutSharedAndroidOptions('''
SecureStorageGate(FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
));
'''),
        1,
      );
      // 別の Android options を渡す。
      expect(
        constructionsWithoutSharedAndroidOptions(
          'FlutterSecureStorage(aOptions: AndroidOptions())',
        ),
        1,
      );
    });

    test('当ててはいけない形に当たらない', () {
      // 入れ子の括弧があっても、共通の値を渡していれば通す。
      expect(
        constructionsWithoutSharedAndroidOptions('''
FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  aOptions: kSecureStorageAndroidOptions,
)
'''),
        0,
      );
      // 型注釈は呼び出しではない。
      expect(
        constructionsWithoutSharedAndroidOptions(
          'AccountStorage([FlutterSecureStorage? storage]);',
        ),
        0,
      );
      // コメント・文字列の中は対象外（normalize 後に見る前提）。
      expect(
        constructionsWithoutSharedAndroidOptions(
          normalize('''
// const s = FlutterSecureStorage();
const doc = 'FlutterSecureStorage()';
'''),
        ),
        0,
      );
    });

    // ⚠⚠ 修正前の実物を食わせる（3 点セットの 3）。
    test('⚠⚠ 修正前の 3 ファイルは全部当たる', () {
      // #1120 を直す直前の main（v1.65.0 の出荷物）。
      const preFix = 'e5f63574';
      for (final path in const [
        'lib/src/service/account_storage.dart',
        'lib/src/service/push_key_store.dart',
        'lib/src/service/device_install_id.dart',
      ]) {
        final shown = Process.runSync('git', [
          '-C',
          '../..',
          'show',
          '$preFix:packages/capsicum/$path',
        ]);
        if (shown.exitCode != 0) {
          markTestSkipped('git show が使えない ($preFix): ${shown.stderr}');
          return;
        }
        expect(
          constructionsWithoutSharedAndroidOptions(
            normalize(shown.stdout as String),
          ),
          greaterThan(0),
          reason: '修正前の $path は Android options を渡していなかったはず',
        );
      }
    });
  });
}
