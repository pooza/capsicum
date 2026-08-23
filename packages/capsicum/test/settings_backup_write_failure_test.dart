import 'package:capsicum/src/service/settings_backup.dart';
import 'package:capsicum/src/ui/util/settings_backup_apply.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// 書き込みを拒む prefs。`SharedPreferences` の setter は失敗しても投げず
/// **false を返す**ので、この形でしか再現できない（compose_draft_store_test の
/// `_RejectingStore` と同じ理由）。
class _RejectingStore extends InMemorySharedPreferencesStore {
  _RejectingStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

/// v1.60 リリース前レビュー（エラー処理・観測性）で出た 2 件の回帰テスト。
///
/// どちらも「宣言と実態のズレ」型。doc / コメントが**やると書いていること**を、
/// 実装が満たしていなかった。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ⚠ **実在するキーで書く。**存在しないキーは「不明な設定です」で skipped に
  // 入るので、`skipped` を見るだけの検査は**実装が壊れていても緑になる**。
  // 型の 4 分岐（bool / number / text / textList）を 1 本ずつ通す。
  const yaml = '''
version: 1
settings:
  absolute_time: true
  font_scale: 1.2
  theme_mode: dark
  compose_template_history:
    - おはよう
''';
  const keys = [
    'absolute_time',
    'font_scale',
    'theme_mode',
    'compose_template_history',
  ];

  group('設定の書き込み失敗を成功として数えない', () {
    // ⚠ `_writeValue` が setter の戻り値を捨てていたため、書けなくても
    // `applied` に積まれ、画面には「N 件の設定を読み込みました」が出ていた。
    // 再起動すると設定は元のまま＝無言の部分失敗。
    test('setter が false を返したら applied ではなく skipped へ入る', () async {
      SharedPreferencesStorePlatform.instance = _RejectingStore();
      addTearDown(() {
        SharedPreferencesStorePlatform.instance =
            InMemorySharedPreferencesStore.empty();
      });
      final prefs = await SharedPreferences.getInstance();

      final result = await applySettingsBackupYaml(prefs, yaml);

      expect(result.applied, isEmpty, reason: '書けていないものを「読み込んだ」と数えてはいけない');
      expect(result.skipped.keys, containsAll(keys));
      expect(result.skipped.values.toSet(), {
        '設定を保存できませんでした',
      }, reason: '「不明な設定です」で通っていたら検査になっていない');
    });

    test('書けたときは applied に入る（検査が常に赤ではない）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();

      final result = await applySettingsBackupYaml(prefs, yaml);

      expect(result.applied, containsAll(keys));
      expect(result.skipped, isEmpty);
    });
  });

  group('取り込めなかった理由をユーザーに出す', () {
    // ⚠ `_mergeAccounts` は「取り込めなかったことは理由つきで返し、ユーザーには
    // 『ログインし直す』という手が残る」と宣言して理由を組み立てていたのに、
    // 画面はその値を読まず件数しか出していなかった。#621 を踏んだ端末では
    // アカウントが 1 件も入らないまま「1 件は取り込みませんでした」で終わる。
    test('accounts の理由は本文をそのまま出す', () {
      const reason =
          '2 件のアカウントは、この端末に古い認証情報が残っているか'
          '確認できなかったため取り込みませんでした';
      final note = settingsBackupSkippedNote(
        const SettingsImportResult(applied: [], skipped: {'accounts': reason}),
      );

      expect(note, contains(reason), reason: '件数だけでは何をすればよいか伝わらない');
    });

    test('設定キーの skip は件数のまま（正常系で本文を並べない）', () {
      final note = settingsBackupSkippedNote(
        const SettingsImportResult(
          applied: [],
          skipped: {
            'window_width': 'この端末固有の設定のため取り込みません',
            'window_height': 'この端末固有の設定のため取り込みません',
          },
        ),
      );

      expect(note, '（2 件は取り込みませんでした）');
    });

    test('両方あるときは accounts の本文＋残りの件数', () {
      final note = settingsBackupSkippedNote(
        const SettingsImportResult(
          applied: [],
          skipped: {
            'accounts': 'アカウントの一覧を保存できませんでした',
            'window_width': 'この端末固有の設定のため取り込みません',
          },
        ),
      );

      expect(note, contains('アカウントの一覧を保存できませんでした'));
      expect(note, contains('1 件'));
    });

    test('何も落ちていなければ空', () {
      expect(
        settingsBackupSkippedNote(
          const SettingsImportResult(applied: ['a'], skipped: {}),
        ),
        isEmpty,
      );
    });
  });
}
