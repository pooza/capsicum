import 'dart:io';

import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/service/settings_backup.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1144: 取り込んだアカウント別設定を画面へ反映する provider の対応検査。
///
/// #1119 で `accountScopedSettings` を足したとき、反映側
/// （`backedUpPreferenceProviders`）には何も足さなかったので、**タブ構成も
/// アカウント色も再起動するまで変わらなかった**。件数の 1:1 検査は
/// `exportableSettings` しか見ていなかった。
///
/// ⚠ **1 つの prefix を複数の provider が読む**ので、件数ではなく「その prefix を
/// 読んでいる notifier の provider が全部入っているか」をソースで見る。

/// `const _fooPrefix = 'foo_';` → {'_fooPrefix': 'foo_'}
Map<String, String> prefixConstants(String code) => {
  for (final m in RegExp(
    r"^const (_[A-Za-z]+Prefix) = '([^']+)';",
    multiLine: true,
  ).allMatches(code))
    m.group(1)!: m.group(2)!,
};

/// notifier のクラス名 → それを作る provider の名前。
Map<String, String> providerOfNotifier(String code) => {
  for (final m in RegExp(
    r'final ([a-zA-Z]+Provider) =\s*[A-Za-z]+(?:\.family)?\s*<\s*([A-Za-z]+)',
  ).allMatches(code))
    m.group(2)!: m.group(1)!,
};

/// prefix の値 → その prefix を本文で使っている notifier の provider 名。
Map<String, Set<String>> readersByPrefix(String code) {
  final consts = prefixConstants(code);
  final providers = providerOfNotifier(code);
  final result = <String, Set<String>>{};
  // ⚠ `class X\n    extends` のように改行を挟む宣言がある（\s で拾う）。
  final classes = RegExp(
    r'^class ([A-Za-z]+)\s+extends',
    multiLine: true,
  ).allMatches(code).toList();
  // ⚠ 本体の終わりは「次のトップレベル宣言」。次の class で切ると、最後の
  // クラスがファイル末尾（対応表そのもの）まで飲み込む。
  final topLevel = RegExp(
    r'^(?:class|final|const|enum|typedef|mixin|extension|abstract)\b',
    multiLine: true,
  ).allMatches(code).map((m) => m.start).toList();
  for (var i = 0; i < classes.length; i++) {
    final start = classes[i].start;
    final end = topLevel.firstWhere(
      (p) => p > start,
      orElse: () => code.length,
    );
    final body = code.substring(start, end);
    final provider = providers[classes[i].group(1)!];
    if (provider == null) continue;
    consts.forEach((name, value) {
      if (RegExp('\\b$name\\b').hasMatch(body)) {
        (result[value] ??= {}).add(provider);
      }
    });
  }
  return result;
}

/// 対応表のソース（`_fooPrefix: [a, b],`）から、prefix の値 → provider 名。
Map<String, Set<String>> declaredByPrefix(String code) {
  final consts = prefixConstants(code);
  final start = code.indexOf('final backedUpAccountScopedProviders');
  if (start < 0) return {};
  final end = code.indexOf('};', start);
  final literal = code.substring(start, end);
  return {
    for (final m in RegExp(
      r'(_[A-Za-z]+Prefix):\s*\[([^\]]*)\]',
    ).allMatches(literal))
      consts[m.group(1)!]!: m
          .group(2)!
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet(),
  };
}

void main() {
  // ⚠ **文字列は潰さない。**prefix の値は文字列リテラルで、使う側も
  // `'\$_fooPrefix\$arg'` のように文字列の中へ埋め込んでいる。
  final raw = maskComments(
    File('lib/src/provider/preferences_provider.dart').readAsStringSync(),
  );

  test('対応表のキーはアカウント別設定の prefix と一致する', () {
    expect(
      backedUpAccountScopedProviders.keys.toSet(),
      accountScopedSettings.map((s) => s.prefix).toSet(),
      reason:
          'accountScopedSettings と backedUpAccountScopedProviders が食い違って'
          'いる。アカウント別設定を足したら、それを読む provider も足すこと',
    );
  });

  test('探索が空振りしていない', () {
    expect(prefixConstants(raw).length, greaterThanOrEqualTo(9));
    final readers = readersByPrefix(raw);
    // 既知の対応が拾えていること（正規表現が壊れたら空で緑になる）。
    expect(readers['tab_order_'], containsAll(['tabOrderProvider']));
    expect(readers['emoji_palette_'], contains('emojiPaletteProvider'));
    expect(declaredByPrefix(raw), isNotEmpty);
  });

  test('⚠⚠ prefix を読む provider が全部、対応表に入っている', () {
    final readers = readersByPrefix(raw);
    final declared = declaredByPrefix(raw);
    final missing = <String>[];
    for (final setting in accountScopedSettings) {
      final need = readers[setting.prefix] ?? const <String>{};
      final have = declared[setting.prefix] ?? const <String>{};
      final lacking = need.difference(have);
      if (lacking.isNotEmpty) {
        missing.add('${setting.prefix}: ${lacking.join(', ')}');
      }
    }
    expect(
      missing,
      isEmpty,
      reason:
          'この prefix を読んでいるのに、取り込み後に invalidate されない provider '
          'がある。値は保存されても再起動まで画面に出ない\n${missing.join('\n')}',
    );
  });

  group('走査に歯がある', () {
    const synthetic = '''
const _fooPrefix = 'foo_';
final fooProvider = NotifierProvider.family<FooNotifier, int, String>(
  FooNotifier.new,
);
class FooNotifier extends FamilyNotifier<int, String> {
  int build(String arg) => prefs.getInt('\$_fooPrefix\$arg') ?? 0;
}
final barProvider =
    NotifierProvider.family<BarNotifier, int, String>(BarNotifier.new);
class BarNotifier
    extends FamilyNotifier<int, String> {
  int build(String arg) => prefs.getInt('\$_fooPrefix\$arg') ?? 1;
}
final bazProvider = NotifierProvider<BazNotifier, int>(BazNotifier.new);
class BazNotifier extends Notifier<int> {
  int build() => 2;
}
final backedUpAccountScopedProviders = <String, List<ProviderOrFamily>>{
  _fooPrefix: [fooProvider],
};
''';

    // ⚠ Bar は `extends` の前で改行している。Baz は最後のクラスで、後ろに
    // 対応表（中に _fooPrefix がある）が続く —— どちらも初版が誤読した形。
    test('読んでいる provider を 2 つとも拾い、読んでいないものは拾わない', () {
      expect(readersByPrefix(synthetic)['foo_'], {
        'fooProvider',
        'barProvider',
      });
    });

    test('対応表から漏れた provider が差分に出る', () {
      final need = readersByPrefix(synthetic)['foo_']!;
      final have = declaredByPrefix(synthetic)['foo_']!;
      expect(need.difference(have), {'barProvider'});
    });
  });
}
