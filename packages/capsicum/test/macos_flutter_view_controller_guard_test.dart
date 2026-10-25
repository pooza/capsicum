import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/git_show.dart';

/// macOS の `FlutterViewController` を、既定の `FlutterDartProject` のまま
/// 作っていることを見る (#1327)。
///
/// ⚠⚠ **`FlutterDartProject` をサブクラスにすると、本文の改行が空白のように
/// 描かれる。**エンジンの `-[FlutterDartProject ICUDataPath]` は `icudtl.dat` を
/// `[NSBundle bundleForClass:[self class]]` から探すので、サブクラスだとアプリ
/// 本体のバンドルを見に行って ICU を見失い、行の区切りが計算できなくなる。
/// #1299（Intel Mac でだけ Impeller を外す）でサブクラスを入れた v2.4.1 の
/// TestFlight で全 Mac に出て、v2.5 で #1299 ごと外した。
///
/// ⚠ エラーにもクラッシュにもならず、**ログに 1 行出るだけ**
/// （`Failed to find path for "icudtl.dat"`）なので、見た目でしか気付けない。
void main() {
  const swiftPath = 'macos/Runner/MainFlutterWindow.swift';

  group('判定（合成ソース）', () {
    const good = '''
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
  }
}
''';

    test('既定の FlutterViewController() は問題なし', () {
      expect(dartProjectProblems(good), isEmpty);
    });

    test('⚠⚠ FlutterDartProject のサブクラスを定義すると落ちる（v2.4.1 の形）', () {
      const v241 = '''
final class CapsicumDartProject: FlutterDartProject {
  #if arch(x86_64)
    @objc(enableImpeller) var capsicumEnableImpeller: Bool { false }
  #endif
}
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController(
      project: CapsicumDartProject(precompiledDartBundle: nil)
    )
  }
}
''';
      expect(dartProjectProblems(v241), isNotEmpty);
    });

    test('⚠⚠ x86_64 の中だけでもサブクラスを定義すると落ちる', () {
      const x86Only = '''
#if arch(x86_64)
  final class CapsicumDartProject: FlutterDartProject {}
#endif
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
  }
}
''';
      expect(dartProjectProblems(x86Only), isNotEmpty);
    });

    test('project: を渡すと落ちる（既定の project を使っていない）', () {
      final src = good.replaceFirst(
        'FlutterViewController()',
        'FlutterViewController(project: FlutterDartProject())',
      );
      expect(dartProjectProblems(src), isNotEmpty);
    });

    test('FlutterViewController を作っていなければ落ちる（走査の空振り）', () {
      expect(
        dartProjectProblems('class MainFlutterWindow: NSWindow {}'),
        isNotEmpty,
      );
    });

    test('コメントの中のサブクラスは数えない', () {
      final src = '// final class X: FlutterDartProject {}\n$good';
      expect(dartProjectProblems(src), isEmpty);
    });
  });

  // ⚠⚠ 3 点セットの 3（#1332）。合成ソースは自分が想定した形しか並べないので、
  // #1327 を起こした実物（v2.4.1 の `085f6612`）を食わせて落ちることを見る。
  test('⚠⚠ #1327 を起こした実物（085f6612）は落ちる', () {
    final before = gitShow('085f6612:packages/capsicum/$swiftPath');
    expect(before.exitCode, 0, reason: before.stderr as String);
    final problems = dartProjectProblems(before.stdout as String);
    expect(problems, contains(startsWith('FlutterDartProject のサブクラスがある')));
  });

  test('アプリの MainFlutterWindow.swift', () {
    final file = File(swiftPath);
    expect(file.existsSync(), isTrue, reason: '走査の対象が無い（パスを確かめる）');
    expect(dartProjectProblems(file.readAsStringSync()), isEmpty);
  });
}

/// 問題を列挙する（空なら問題なし）。
List<String> dartProjectProblems(String swift) {
  final src = maskComments(swift);
  final problems = <String>[];
  if (RegExp(r'class\s+\w+\s*:\s*FlutterDartProject\b').hasMatch(src)) {
    problems.add('FlutterDartProject のサブクラスがある（#1327: ICU を見失い、改行が空白になる）');
  }
  if (!RegExp(r'FlutterViewController\(\s*\)').hasMatch(src)) {
    problems.add('FlutterViewController() を既定の project で作っていない');
  }
  if (RegExp(r'FlutterViewController\(\s*project:').hasMatch(src)) {
    problems.add('FlutterViewController に project を渡している');
  }
  return problems;
}
