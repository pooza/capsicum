import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/settings_backup.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1119: アカウント別設定（タブ構成・ピン留めタグ・リストの並び・絵文字
/// パレット等）をバックアップに含める。
///
/// ⚠⚠ **除外の理由が古くなっていた。**「どのアカウントへ入れるか決められない」は
/// アカウント索引の同梱（#967 / #1001・v1.59 出荷）で成り立たなくなっている。
/// 実害は「別端末へ移行するとアカウントは並ぶのに、その中身の設定だけ真っさら」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const alice = 'mastodon://alice@mstdn.example';
  const bob = 'misskey://bob@misskey.example';

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  String yamlOf(SharedPreferences prefs) => buildSettingsBackupYaml(
    prefs,
    appVersion: '1.65.0+184',
    exportedAt: '2026-09-13T12:00:00Z',
  );

  /// ⚠ **secure storage を渡す** — 渡さないと `purgeStaleSecrets` が fail-closed で
  /// 索引に 1 件も入らず、アカウント別設定の取り込み先も無くなる（#1020）。
  Future<SettingsImportResult> apply(SharedPreferences prefs, String yaml) =>
      applySettingsBackupYaml(
        prefs,
        yaml,
        accountStorage: AccountStorage(_NoSecretsStorage()),
      );

  group('書き出し', () {
    test('索引にあるアカウントの設定を account_settings へ書く', () async {
      final prefs = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        'tab_order_$alice': ['home', 'notifications'],
        'pinned_hashtags_$alice': ['precure_fun'],
        'theme_color_$alice': 4291681337,
      });

      final yaml = yamlOf(prefs);

      expect(yaml, contains('account_settings:'));
      expect(yaml, contains('  "$alice":'));
      expect(yaml, contains('    tab_order:'));
      expect(yaml, contains('      - "home"'));
      expect(yaml, contains('    pinned_hashtags:'));
      expect(yaml, contains('    theme_color: 4291681337'));
    });

    test('⚠ 索引に無いアカウントの設定は書かない（accounts と食い違わせない）', () async {
      final prefs = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        'tab_order_$bob': ['home'],
      });

      final yaml = yamlOf(prefs);

      expect(yaml, isNot(contains(bob)));
    });

    test('⚠ 設定を持たないアカウントの空セクションを作らない', () async {
      final prefs = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        'font_scale': 1.2,
      });

      expect(yamlOf(prefs), isNot(contains('account_settings:')));
    });

    // ⚠ **除外した 2 つ。**`last_tab_` は一時状態、`background_opacity` は
    // 背景画像（端末固有パス）が移らないので効く相手が居ない。
    test('⚠ last_tab_ と background_opacity は書かない', () async {
      final prefs = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        'last_tab_$alice': 'timeline:home',
        'background_opacity_$alice': 0.5,
        'background_opacity': 0.4,
        'tab_order_$alice': ['home'],
      });

      final yaml = yamlOf(prefs);

      expect(yaml, contains('account_settings:'));
      expect(yaml, isNot(contains('last_tab')));
      expect(yaml, isNot(contains('background_opacity')));
    });

    test('空のリストは [] として書く（「空にした」と「未設定」を区別する）', () async {
      final prefs = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        'pinned_hashtags_$alice': <String>[],
      });

      expect(yamlOf(prefs), contains('    pinned_hashtags: []'));
    });
  });

  group('読み込み', () {
    String yamlWith(String accountsBlock, String accountSettingsBlock) => [
      'version: 1',
      accountsBlock,
      accountSettingsBlock,
      'settings: {}',
    ].join('\n');

    test('索引ごと空の端末へ、アカウントと設定がまとめて入る', () async {
      // ⚠ 移行の主経路。`accounts:` のマージで索引が生まれた**あとに**
      // account_settings を見ないと、行き先が無いと判定して全部落ちる。
      final prefs = await prefsWith({});

      final result = await apply(
        prefs,
        yamlWith(
          'accounts:\n  - "$alice"',
          'account_settings:\n'
              '  "$alice":\n'
              '    tab_order:\n'
              '      - home\n'
              '      - notifications\n'
              '    theme_color: 4291681337',
        ),
      );

      expect(prefs.getStringList('tab_order_$alice'), [
        'home',
        'notifications',
      ]);
      expect(prefs.getInt('theme_color_$alice'), 4291681337);
      expect(result.applied, contains('tab_order_$alice'));
      expect(result.skipped, isNot(contains('account_settings')));
    });

    test('⚠⚠ 索引に無いアカウントの設定は書かない（触れない設定を溜めない）', () async {
      final prefs = await prefsWith({});

      final result = await apply(
        prefs,
        yamlWith(
          'accounts:\n  - "$alice"',
          'account_settings:\n  "$bob":\n    tab_order:\n      - home',
        ),
      );

      expect(prefs.getStringList('tab_order_$bob'), isNull);
      expect(result.skipped['account_settings'], contains('この端末に無いアカウント'));
    });

    test('⚠ 落ちた理由のキーは定数（アカウント名を skipped のキーにしない）', () async {
      // #1012 で塞いだ「キー名の側から素通し」を開け直さないための固定。
      final prefs = await prefsWith({});

      final result = await apply(
        prefs,
        yamlWith(
          'accounts: []',
          'account_settings:\n  "$bob":\n    tab_order:\n      - home',
        ),
      );

      expect(result.skipped.keys, contains('account_settings'));
      expect(result.skipped.keys, isNot(contains(bob)));
    });

    test('型が合わない値は取り込まず、他の設定は通す', () async {
      final prefs = await prefsWith({});

      final result = await apply(
        prefs,
        yamlWith(
          'accounts:\n  - "$alice"',
          'account_settings:\n'
              '  "$alice":\n'
              '    tab_order: 12\n'
              '    pinned_hashtags:\n'
              '      - precure_fun',
        ),
      );

      expect(prefs.getStringList('tab_order_$alice'), isNull);
      expect(prefs.getStringList('pinned_hashtags_$alice'), ['precure_fun']);
      expect(result.skipped['account_settings'], contains('形式'));
    });

    test('⚠ theme_color に小数が書かれていたら通さない（setInt と読みがずれる）', () async {
      final prefs = await prefsWith({});

      await apply(
        prefs,
        yamlWith(
          'accounts:\n  - "$alice"',
          'account_settings:\n  "$alice":\n    theme_color: 1.5',
        ),
      );

      expect(prefs.getInt('theme_color_$alice'), isNull);
    });

    test('知らない設定名は取り込まない', () async {
      final prefs = await prefsWith({});

      final result = await apply(
        prefs,
        yamlWith(
          'accounts:\n  - "$alice"',
          'account_settings:\n  "$alice":\n    nonexistent_setting: 1',
        ),
      );

      expect(prefs.getInt('nonexistent_setting_$alice'), isNull);
      expect(result.skipped['account_settings'], isNotNull);
    });

    test('account_settings が map でなければ理由を残して何もしない', () async {
      final prefs = await prefsWith({});

      final result = await apply(
        prefs,
        yamlWith('accounts:\n  - "$alice"', 'account_settings: 42'),
      );

      expect(result.skipped['account_settings'], contains('読めませんでした'));
    });

    test('account_settings が無いファイル（旧版）も読める', () async {
      final prefs = await prefsWith({});

      final result = await apply(
        prefs,
        'version: 1\nsettings:\n  font_scale: 1.2',
      );

      expect(result.skipped, isNot(contains('account_settings')));
      expect(prefs.getDouble('font_scale'), 1.2);
    });
  });

  test('⚠ 書き出したファイルを読み込むと元に戻る（ラウンドトリップ）', () async {
    final source = await prefsWith({
      'capsicum_account_keys_v2': '["$alice","$bob"]',
      'tab_order_$alice': ['home', 'local'],
      'hidden_list_ids_$alice': ['3'],
      'emoji_palette_$bob': [':capsicum:', ':precure:'],
      'theme_color_$bob': 4278190080,
    });
    final yaml = yamlOf(source);

    final target = await prefsWith({});
    await apply(target, yaml);

    expect(target.getStringList('tab_order_$alice'), ['home', 'local']);
    expect(target.getStringList('hidden_list_ids_$alice'), ['3']);
    expect(target.getStringList('emoji_palette_$bob'), [
      ':capsicum:',
      ':precure:',
    ]);
    expect(target.getInt('theme_color_$bob'), 4278190080);
  });
}

/// 残骸 secret が無い状態を与える（`purgeStaleSecrets` の fail-closed を避ける）。
class _NoSecretsStorage extends FlutterSecureStorage {
  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => false;
}
