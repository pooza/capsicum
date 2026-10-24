import 'dart:io';

import 'package:capsicum/src/service/settings_backup.dart';
import 'package:capsicum/src/ui/util/settings_backup_apply.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/git_show.dart';

/// #1317: 取り込んだ節は全部、実行中のアプリへ反映する。
///
/// ⚠⚠ **`settings:` の外の節が反映から漏れていた。**取り込み後に読み直していた
/// のは `settings:` と `account_settings:` のぶんだけで、`deck_columns:` を
/// 取り込んでも**デッキは起動時の列（新しい端末なら空）のまま**だった。その状態で
/// カラムを 1 本足すと、画面の列で保存し直すので**取り込んだ構成が消える**。
///
/// 件数の検査（`settings_backup_providers_test`）は `exportableSettings` しか
/// 数えないので、トップレベルの節は見えなかった。ここでは
/// **取り込み処理が読んでいる節**（`applySettingsBackupYaml` の `parsed[...]`）を
/// ソースから拾い、[backedUpSectionProviders] に全部あるかを見る。
void main() {
  /// 節の名前を定数で読んでいるもの。⚠ 増えたらここにも足す（知らない定数は
  /// 下の検査が落とす）。
  const constants = {
    'deckColumnsBackupKey': deckColumnsBackupKey,
    'deckLockedColumnsBackupKey': deckLockedColumnsBackupKey,
  };

  /// 状態を持たないので読み直すものが無い節。
  const stateless = {'version'};

  /// `applySettingsBackupYaml` の本体で `parsed[...]` として読んでいる節。
  Set<String> sectionsRead(String source) {
    final masked = maskComments(source);
    final start = masked.indexOf(
      'Future<SettingsImportResult> applySettingsBackupYaml(',
    );
    if (start < 0) return const {};
    final end = masked.indexOf('\n}\n', start);
    final body = masked.substring(start, end < 0 ? masked.length : end);
    return {
      for (final m in RegExp(
        r"parsed\[\s*(?:'([^']+)'|([A-Za-z_]+))\s*\]",
      ).allMatches(body))
        m.group(1) ?? constants[m.group(2)!] ?? '(知らない定数 ${m.group(2)})',
    };
  }

  final current = sectionsRead(
    File('lib/src/service/settings_backup.dart').readAsStringSync(),
  );

  group('⚠ 走査が空振りしていない', () {
    test('取り込み処理の既知の節を拾えている', () {
      expect(
        current,
        containsAll([
          'version',
          'settings',
          'accounts',
          'account_settings',
          deckColumnsBackupKey,
          deckLockedColumnsBackupKey,
        ]),
      );
    });

    test('節の名前の定数は全部、名前を解決できている', () {
      expect(current.where((s) => s.startsWith('(知らない定数')), isEmpty);
    });
  });

  test('⚠ 判定に合成ソースを食わせる', () {
    const synthetic = '''
Future<SettingsImportResult> applySettingsBackupYaml(
  SharedPreferences prefs,
  String yamlText,
) async {
  final a = parsed['settings'];
  // parsed['commented'] は読まない
  final b = parsed[deckColumnsBackupKey];
  final c = parsed[ unknownKey ];
}
Object other() => parsed['outside'];
''';
    expect(sectionsRead(synthetic), {
      'settings',
      deckColumnsBackupKey,
      '(知らない定数 unknownKey)',
    });
  });

  test(
    '⚠⚠ 修正前の対応（settings / account_settings / accounts）では deck_columns が漏れる',
    () {
      // `b5d6147f` = #1317 の修正の直前。このときの反映は `settings:` の provider と
      // アカウント別設定の provider の invalidate と、索引の積み直しだけだった。
      final before = gitShow(
        'b5d6147f:packages/capsicum/lib/src/service/settings_backup.dart',
      );
      expect(before.exitCode, 0, reason: (before.stderr as String));
      final read = sectionsRead(before.stdout as String);
      const refreshedThen = {'settings', 'account_settings', 'accounts'};
      expect(read.difference({...refreshedThen, ...stateless}), {
        deckColumnsBackupKey,
      });
    },
  );

  test('取り込み処理が読む節は全部、読み直しの対応表にある', () {
    final missing = current
        .difference(stateless)
        .difference(backedUpSectionProviders.keys.toSet());
    expect(
      missing,
      isEmpty,
      reason:
          '取り込むのに、取り込んだ後に読み直さない節がある。値は保存されても '
          '再起動まで画面に出ない（読み直す provider が無い節は、空の一覧と理由を '
          'backedUpSectionProviders に書く）',
    );
  });

  test('対応表に、取り込み処理が読まない節が残っていない', () {
    expect(backedUpSectionProviders.keys.toSet().difference(current), isEmpty);
  });
}
