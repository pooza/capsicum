import 'package:capsicum/src/ui/util/compose_text_style.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1233: 投稿フォームのフォント設定（#892）を、本文を書く欄すべてに当てる。
///
/// 以前は投稿の本文 1 か所にだけ `TextStyle(fontFamily: …)` を直に組んでいて、
/// Annict の感想や投稿テンプレートの本文には当たっていなかった。当て方を
/// `composeTextStyle` の 1 か所へ寄せ、**当てている場所をここで数える**。
///
/// 線引き（どの欄に当てるか）は `compose_text_style.dart` の冒頭にある。
void main() {
  /// 当てている画面。⚠ **増やす・減らすときは、`compose_text_style.dart` の
  /// 表も直す**（線引きの正本はあちら）。
  const appliedIn = {
    'lib/src/ui/screen/compose_screen.dart',
    'lib/src/ui/screen/annict_review_screen.dart',
    'lib/src/ui/screen/templates_manage_screen.dart',
  };

  late Map<String, String> sources;

  setUpAll(() {
    sources = {
      for (final file in sourceFiles('lib/src', skipGenerated: true))
        file.path: maskStrings(maskComments(file.readAsStringSync())),
    };
  });

  group('スタイルの組み立て', () {
    test('⚠ 設定が空なら null（テーマの既定のまま・見た目を変えない）', () {
      expect(composeTextStyleOf(''), isNull);
    });

    test('設定があれば、そのフォントを指す', () {
      expect(composeTextStyleOf('HackGen')?.fontFamily, 'HackGen');
    });
  });

  group('⚠ 走査が空振りしていない', () {
    test('lib のソースを読めている', () {
      expect(sources.length, greaterThan(200));
      for (final path in appliedIn) {
        expect(sources.keys, contains(path));
      }
    });

    test('ヘルパーの本体は設定を読んでいる', () {
      expect(
        sources['lib/src/ui/util/compose_text_style.dart'],
        contains('composeFontFamilyProvider'),
      );
    });
  });

  test('当てている画面が、表のとおり', () {
    final callers = {
      for (final entry in sources.entries)
        if (appliesComposeTextStyle(entry.value) &&
            !entry.key.endsWith('/compose_text_style.dart'))
          entry.key,
    };
    expect(callers, appliedIn);
  });

  test('⚠ 設定を画面が直に読んで、スタイルを自前で組んでいない', () {
    // 設定を直に読んでよいのは、ヘルパー・設定の定義・設定画面だけ。
    const allowed = {
      'lib/src/ui/util/compose_text_style.dart',
      'lib/src/provider/preferences_provider.dart',
      'lib/src/ui/screen/settings/desktop_settings_screen.dart',
    };
    final offenders = [
      for (final entry in sources.entries)
        if (readsComposeFontDirectly(entry.value) &&
            !allowed.contains(entry.key))
          entry.key,
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          'composeFontFamilyProvider を直に読んでいる。'
          'composeTextStyle(ref) を使うこと（次に設定が増えたときに取り残す）',
    );
    // ⚠ 許可した 3 つが実在して、実際に読んでいること（表が腐っていない）。
    for (final path in allowed) {
      expect(
        readsComposeFontDirectly(sources[path] ?? ''),
        isTrue,
        reason: '$path は設定を読んでいない。許可の表から外すこと',
      );
    }
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('当てている形', () {
      expect(appliesComposeTextStyle('style: composeTextStyle(ref),'), isTrue);
      expect(
        appliesComposeTextStyle('final s = composeTextStyle(ref);'),
        isTrue,
      );
    });

    test('当てていない形', () {
      // 別の名前の一部。
      expect(appliesComposeTextStyle('myComposeTextStyle(ref)'), isFalse);
      // 空のとき用の関数だけを呼んでいる（設定を読まない）。
      expect(appliesComposeTextStyle("composeTextStyleOf('x')"), isFalse);
      // コメントと文字列は、潰してから渡す前提。
      expect(
        appliesComposeTextStyle(
          maskStrings(
            maskComments(
              "// composeTextStyle(ref)\nlog('composeTextStyle(ref)');",
            ),
          ),
        ),
        isFalse,
      );
    });

    test('設定を直に読んでいる形・いない形', () {
      expect(
        readsComposeFontDirectly('ref.watch(composeFontFamilyProvider)'),
        isTrue,
      );
      expect(
        readsComposeFontDirectly(
          'ref.read(composeFontFamilyProvider.notifier)',
        ),
        isTrue,
      );
      expect(readsComposeFontDirectly('composeTextStyle(ref)'), isFalse);
    });
  });
}

/// `composeTextStyle(` を呼んでいるか（`composeTextStyleOf(` や、別の名前の
/// 一部は数えない）。
bool appliesComposeTextStyle(String source) =>
    RegExp(r'(^|[^\w])composeTextStyle\(').hasMatch(source);

/// フォントの設定を直に読んでいるか。
bool readsComposeFontDirectly(String source) =>
    RegExp(r'\bcomposeFontFamilyProvider\b').hasMatch(source);
