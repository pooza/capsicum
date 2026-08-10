import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/service/settings_backup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #857: 読み込んだ数値が設定の許容範囲を外れていないか。
///
/// 「SharedPreferences に入っている数値は必ず範囲内」という不変条件を、
/// これまで setter の clamp だけが守っていた（読み手は無検査で state に入れる）。
/// バックアップは平文 YAML の手編集が想定内なので、`1.4` を `14` と打ち間違える
/// だけで全テキストが 14 倍になり、設定画面へ戻れず再インストール以外で
/// 直せなくなる。**永続化される前に弾く**ことをここで固定する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  BackupSetting settingFor(String key) =>
      exportableSettings.firstWhere((s) => s.key == key);

  Future<SharedPreferences> emptyPrefs() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  // settings_backup.dart は provider を import しない純粋な service なので、
  // 範囲の数値が二重管理になる。ずれたらここで落とす。
  test('許容範囲は preferences_provider の定数と一致する', () {
    expect(settingFor('font_scale').min, minFontScale);
    expect(settingFor('font_scale').max, maxFontScale);
    expect(settingFor('emoji_scale').min, minEmojiSize);
    expect(settingFor('emoji_scale').max, maxEmojiSize);
    expect(settingFor('thumbnail_scale').min, minThumbnailScale);
    expect(settingFor('thumbnail_scale').max, maxThumbnailScale);
  });

  test('範囲を外れた数値は永続化されず、理由つきで skipped に載る', () async {
    final prefs = await emptyPrefs();

    // 1.4 を 14 と打ち間違えた場合。
    final result = await applySettingsBackupYaml(prefs, '''
version: 1
settings:
  font_scale: 14
''');

    expect(result.applied, isEmpty);
    expect(result.skipped.keys, ['font_scale']);
    expect(result.skipped['font_scale'], contains('範囲'));
    expect(prefs.getDouble('font_scale'), isNull);
  });

  // NaN / Infinity は大小比較がどちらも false になるため、範囲チェックだけでは
  // すり抜ける。すり抜けると TextScaler.linear(NaN) がレイアウトごと壊す。
  test('.nan と .inf は取り込まない', () async {
    for (final literal in ['.nan', '.inf', '-.inf']) {
      final prefs = await emptyPrefs();
      final result = await applySettingsBackupYaml(prefs, '''
version: 1
settings:
  font_scale: $literal
''');

      expect(result.applied, isEmpty, reason: literal);
      expect(prefs.getDouble('font_scale'), isNull, reason: literal);
    }
  });

  test('範囲内の値と境界値は取り込む', () async {
    final prefs = await emptyPrefs();

    final result = await applySettingsBackupYaml(prefs, '''
version: 1
settings:
  font_scale: $maxFontScale
  thumbnail_scale: $minThumbnailScale
  emoji_scale: 24
''');

    expect(result.skipped, isEmpty);
    expect(prefs.getDouble('font_scale'), maxFontScale);
    expect(prefs.getDouble('thumbnail_scale'), minThumbnailScale);
    expect(prefs.getDouble('emoji_scale'), 24);
  });

  // 素の background_opacity は移行専用キーで、書き込むと per-account 値を
  // まだ持たない**全アカウント**へ染み出す。対象から外したことを固定する。
  test('background_opacity は書き出さず、読み込んでも書かない', () async {
    SharedPreferences.setMockInitialValues({
      'background_opacity_a@b.example': 0.4,
    });
    final prefs = await SharedPreferences.getInstance();

    expect(
      buildSettingsBackupYaml(
        prefs,
        appVersion: '1.55.0+168',
        exportedAt: '2026-08-10T00:00:00.000Z',
      ),
      isNot(contains('background_opacity')),
    );

    final result = await applySettingsBackupYaml(prefs, '''
version: 1
settings:
  background_opacity: 0.5
''');

    expect(result.applied, isEmpty);
    expect(result.skipped['background_opacity'], contains('アカウントごと'));
    expect(prefs.getDouble('background_opacity'), isNull);
    expect(prefs.getDouble('background_opacity_a@b.example'), 0.4);
  });
}
