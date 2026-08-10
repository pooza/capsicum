import 'dart:io';

import 'package:capsicum/src/service/settings_backup.dart';
import 'package:flutter_test/flutter_test.dart';

/// #857: バックアップの取りこぼしを防ぐカバレッジ検査。
///
/// 設定を追加したときに [exportableSettings] へ足し忘れると、**黙って**
/// バックアップから漏れる（エクスポートしたのに移らない設定が出る）。ここで
/// `preferences_provider.dart` のキー定義と突き合わせ、
/// 「対象」でも「意図的に外した」（[deviceLocalKeys]）でもないキーを落とす。
///
/// ソースを読む検査なのは、設定キーが 2,000 行のプロバイダに定数として散って
/// いて、実行時に列挙する手段が無いため。キー定義の書式
/// （`const _xxxKey = 'yyy';`）が変わったらこのテストも直す。
void main() {
  test('設定キーはすべてバックアップ対象か、意図的な除外かのどちらかである', () {
    final source = File(
      'lib/src/provider/preferences_provider.dart',
    ).readAsStringSync();

    final keys = RegExp(
      r"^const _[A-Za-z]+Key = '([^']+)';",
      multiLine: true,
    ).allMatches(source).map((m) => m.group(1)!).toSet();

    // 書式が変わって 0 件になると、検査が素通りして意味を失う。
    expect(
      keys.length,
      greaterThan(20),
      reason: 'キー定義を拾えていない。正規表現が実装とずれた可能性がある',
    );

    final covered = {
      ...exportableSettings.map((s) => s.key),
      ...deviceLocalKeys,
      ...accountScopedKeys,
    };
    final missing = keys.difference(covered);

    expect(
      missing,
      isEmpty,
      reason:
          '新しい設定がバックアップの仕分けから漏れている。'
          'exportableSettings に足すか、端末固有なら deviceLocalKeys、'
          'アカウントごとなら accountScopedKeys に足すこと',
    );
  });

  test('バックアップ対象と意図的な除外は重ならない', () {
    final exported = exportableSettings.map((s) => s.key).toSet();
    expect(exported.intersection(deviceLocalKeys), isEmpty);
    expect(exported.intersection(accountScopedKeys), isEmpty);
    expect(deviceLocalKeys.intersection(accountScopedKeys), isEmpty);
  });

  test('バックアップ対象のキーに重複が無い', () {
    final keys = exportableSettings.map((s) => s.key).toList();
    expect(keys.length, keys.toSet().length);
  });
}
