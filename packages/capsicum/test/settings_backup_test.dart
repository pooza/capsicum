import 'package:capsicum/src/service/settings_backup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #857: 設定のバックアップの書き出し / 読み込み。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  String yamlOf(SharedPreferences prefs) => buildSettingsBackupYaml(
    prefs,
    appVersion: '1.55.0+168',
    exportedAt: '2026-08-10T12:00:00Z',
  );

  group('書き出し', () {
    test('設定した値だけを書き、既定のままの設定は書かない', () async {
      final prefs = await prefsWith({'font_scale': 1.2, 'absolute_time': true});

      final yaml = yamlOf(prefs);

      expect(yaml, contains('font_scale: 1.2'));
      expect(yaml, contains('absolute_time: true'));
      // 触っていない設定は書かない。既定値を焼き込むと、後で既定が変わった
      // ときに古い既定値が復活する。
      expect(yaml, isNot(contains('theme_mode')));
    });

    test('アカウント・認証情報は書かない', () async {
      final prefs = await prefsWith({
        'font_scale': 1.2,
        'capsicum_account_keys_v2': '["mstdn.example_pooza"]',
        'capsicum_device_install_id': 'device-abc',
      });

      final yaml = yamlOf(prefs);

      expect(yaml, isNot(contains('account')));
      expect(yaml, isNot(contains('device')));
    });

    test('端末固有の設定は書かない', () async {
      final prefs = await prefsWith({
        'background_image_path': '/Users/pooza/wall.png',
        'reaction_picker_height': 320.0,
        'launch_at_login': true,
      });

      final yaml = yamlOf(prefs);

      for (final key in deviceLocalKeys) {
        expect(yaml, isNot(contains(key)), reason: '$key を書いてはいけない');
      }
    });

    test('区切り文字を含む文字列を壊さない', () async {
      final prefs = await prefsWith({
        'compose_font_family': 'HackGen: Console #1',
        'compose_template_history': <String>['a: b', '# c', 'd"e'],
      });

      final result = await applySettingsBackupYaml(
        await prefsWith({}),
        yamlOf(prefs),
      );

      expect(result.skipped, isEmpty);
      final restored = await SharedPreferences.getInstance();
      expect(restored.getString('compose_font_family'), 'HackGen: Console #1');
      expect(restored.getStringList('compose_template_history'), [
        'a: b',
        '# c',
        'd"e',
      ]);
    });

    test('1 件も設定が無くても読み込める形になる', () async {
      final yaml = yamlOf(await prefsWith({}));

      final result = await applySettingsBackupYaml(await prefsWith({}), yaml);

      expect(result.applied, isEmpty);
      expect(result.skipped, isEmpty);
    });
  });

  group('読み込み', () {
    test('書き出した YAML を別端末で復元できる（往復）', () async {
      final source = await prefsWith({
        'font_scale': 1.2,
        'theme_mode': 'dark',
        'absolute_time': true,
        'emoji_scale': 24.0,
        'recent_emojis': <String>['dai_smile', 'gome_maru'],
      });
      final yaml = yamlOf(source);

      final target = await prefsWith({});
      final result = await applySettingsBackupYaml(target, yaml);

      expect(result.skipped, isEmpty);
      expect(result.applied, hasLength(5));
      expect(target.getDouble('font_scale'), 1.2);
      expect(target.getString('theme_mode'), 'dark');
      expect(target.getBool('absolute_time'), isTrue);
      expect(target.getDouble('emoji_scale'), 24.0);
      expect(target.getStringList('recent_emojis'), ['dai_smile', 'gome_maru']);
    });

    test('整数で書かれた倍率も受ける（YAML の 1 は int になる）', () async {
      final prefs = await prefsWith({});

      await applySettingsBackupYaml(prefs, '''
version: 1
settings:
  font_scale: 1
''');

      expect(prefs.getDouble('font_scale'), 1.0);
    });

    test('知らないキーは飛ばして続行する', () async {
      final prefs = await prefsWith({});

      final result = await applySettingsBackupYaml(prefs, '''
version: 1
settings:
  font_scale: 1.2
  nazono_settei: true
''');

      // 1 つの不整合で全体を捨てると、版をまたいだバックアップが使えなくなる。
      expect(prefs.getDouble('font_scale'), 1.2);
      expect(result.applied, ['font_scale']);
      expect(result.skipped.keys, ['nazono_settei']);
    });

    test('型違いは飛ばし、既存の値を壊さない', () async {
      final prefs = await prefsWith({'font_scale': 1.2});

      final result = await applySettingsBackupYaml(prefs, '''
version: 1
settings:
  font_scale: "おおきく"
''');

      expect(prefs.getDouble('font_scale'), 1.2);
      expect(result.applied, isEmpty);
      expect(result.skipped.keys, ['font_scale']);
    });

    test('端末固有のキーが書かれていても取り込まない', () async {
      final prefs = await prefsWith({});

      final result = await applySettingsBackupYaml(prefs, '''
version: 1
settings:
  background_image_path: "/Users/someone/wall.png"
  launch_at_login: true
''');

      expect(prefs.getString('background_image_path'), isNull);
      expect(prefs.getBool('launch_at_login'), isNull);
      expect(result.skipped, hasLength(2));
    });

    test('新しい版のファイルは更新を促して弾く', () async {
      final prefs = await prefsWith({});

      expect(
        () => applySettingsBackupYaml(prefs, '''
version: 999
settings:
  font_scale: 1.2
'''),
        throwsA(
          isA<SettingsBackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('更新'),
          ),
        ),
      );
    });

    test('設定のバックアップでないファイルは弾く', () async {
      final prefs = await prefsWith({});

      for (final text in ['', 'just text', 'a: 1', '[]']) {
        expect(
          () => applySettingsBackupYaml(prefs, text),
          throwsA(isA<SettingsBackupFormatException>()),
          reason: '「$text」を設定として受けてはいけない',
        );
      }
    });
  });
}
