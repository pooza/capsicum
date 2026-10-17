import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// Intel Mac でだけ Impeller を外す仕掛け (#1299) が生きていることを見る。
///
/// ⚠⚠ **この仕掛けは、黙って効かなくなる形を 2 つ持っている。**
///
/// 1. **アプリ側**: `MainFlutterWindow` が `FlutterViewController()` に戻ると、
///    上書きした `CapsicumDartProject` が使われない。上書きが `#if arch(x86_64)`
///    の外へ出ると、**Apple Silicon でも Impeller が外れる**（全 macOS には
///    効かせない、が 2026-10-18 の pooza 判断）。
/// 2. **エンジン側**: 上書きしているのは非公開の property
///    （`FlutterDartProject_Internal.h` の `enableImpeller`）。上流が名前を変えると、
///    **コンパイルは通るのに上書きが読まれなくなる**。
///
/// 2 はエンジンのソースを持つ Flutter SDK（git の clone）でだけ見られる。CI の
/// SDK にソースが無ければ skip する —— **Flutter の基準版を上げる作業は手元の
/// clone で行う**（`docs/dev-environment.md`「基準版を上げる」）ので、そこで落ちる。
void main() {
  const swiftPath = 'macos/Runner/MainFlutterWindow.swift';

  group('判定（合成ソース）', () {
    const good = '''
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

    test('正しい形は問題なし', () {
      expect(intelOptOutProblems(good), isEmpty);
    });

    test('⚠⚠ FlutterViewController() に戻ると落ちる', () {
      final src = good.replaceFirst(
        RegExp(r'FlutterViewController\([^)]*\)\s*\)'),
        'FlutterViewController()',
      );
      expect(intelOptOutProblems(src), isNotEmpty);
    });

    test('⚠⚠ 上書きが #if arch(x86_64) の外に出ると落ちる（Apple Silicon にも効く）', () {
      final src = good
          .replaceFirst('  #if arch(x86_64)\n', '')
          .replaceFirst('  #endif\n', '');
      expect(intelOptOutProblems(src), isNotEmpty);
    });

    test('上書きがコメントの中にしか無ければ落ちる', () {
      final src = good.replaceFirst(
        '    @objc(enableImpeller)',
        '    // @objc(enableImpeller)',
      );
      expect(intelOptOutProblems(src), isNotEmpty);
    });

    test('selector の名前を間違えると落ちる', () {
      final src = good.replaceFirst(
        '@objc(enableImpeller)',
        '@objc(isImpellerEnabled)',
      );
      expect(intelOptOutProblems(src), isNotEmpty);
    });

    test('true を返していたら落ちる（外していない）', () {
      final src = good.replaceFirst('Bool { false }', 'Bool { true }');
      expect(intelOptOutProblems(src), isNotEmpty);
    });

    test('エンジン: property と読み出しが揃っていれば問題なし', () {
      expect(
        engineOptOutProblems(
          internalHeader: '@property(nonatomic, readonly) BOOL enableImpeller;',
          engineSource: '} else if (_project.enableImpeller || foo) {',
        ),
        isEmpty,
      );
    });

    test('⚠⚠ エンジン: 名前が変わったら落ちる', () {
      expect(
        engineOptOutProblems(
          internalHeader: '@property(nonatomic, readonly) BOOL useImpeller;',
          engineSource: '} else if (_project.useImpeller || foo) {',
        ),
        isNotEmpty,
      );
    });
  });

  test('アプリの MainFlutterWindow.swift', () {
    final file = File(swiftPath);
    expect(file.existsSync(), isTrue, reason: '走査の対象が無い（パスを確かめる）');
    expect(intelOptOutProblems(file.readAsStringSync()), isEmpty);
  });

  test('手元の Flutter SDK のエンジンが、上書きした property を読んでいる', () {
    final root = Platform.environment['FLUTTER_ROOT'];
    final macos = '$root/engine/src/flutter/shell/platform/darwin/macos';
    final header = File(
      '$macos/framework/Source/FlutterDartProject_Internal.h',
    );
    final engine = File('$macos/framework/Source/FlutterEngine.mm');
    if (root == null || !header.existsSync() || !engine.existsSync()) {
      markTestSkipped('エンジンのソースを持たない Flutter SDK（$root）');
      return;
    }
    expect(
      engineOptOutProblems(
        internalHeader: header.readAsStringSync(),
        engineSource: engine.readAsStringSync(),
      ),
      isEmpty,
      reason:
          '上流が enableImpeller の名前か読み方を変えた。#1299 の上書きが'
          '黙って効かなくなっている',
    );
  });
}

/// アプリ側の問題を列挙する（空なら問題なし）。
List<String> intelOptOutProblems(String swift) {
  final src = maskComments(swift);
  final problems = <String>[];
  if (!RegExp(
    r'FlutterViewController\(\s*project:\s*CapsicumDartProject\(',
  ).hasMatch(src)) {
    problems.add('FlutterViewController に CapsicumDartProject を渡していない');
  }
  final block = RegExp(
    r'#if\s+arch\(x86_64\)([\s\S]*?)#endif',
  ).firstMatch(src)?.group(1);
  final override = RegExp(
    r'@objc\(enableImpeller\)\s+var\s+\w+\s*:\s*Bool\s*\{\s*false\s*\}',
  );
  if (block == null || !override.hasMatch(block)) {
    problems.add('#if arch(x86_64) の中に enableImpeller=false の上書きが無い');
  }
  final outside = src.replaceAll(
    RegExp(r'#if\s+arch\(x86_64\)[\s\S]*?#endif'),
    '',
  );
  if (outside.contains('@objc(enableImpeller)')) {
    problems.add('enableImpeller の上書きが x86_64 の外にある（Apple Silicon にも効く）');
  }
  return problems;
}

/// エンジン側の問題を列挙する（空なら問題なし）。
List<String> engineOptOutProblems({
  required String internalHeader,
  required String engineSource,
}) {
  final problems = <String>[];
  if (!RegExp(
    r'@property\([^)]*\)\s*BOOL\s+enableImpeller\s*;',
  ).hasMatch(internalHeader)) {
    problems.add('FlutterDartProject に BOOL enableImpeller が無い');
  }
  if (!engineSource.contains('_project.enableImpeller')) {
    problems.add('FlutterEngine が _project.enableImpeller を読んでいない');
  }
  return problems;
}
