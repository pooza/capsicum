/// 設定のバックアップ（書き出し / 読み込み）(#857)。
///
/// **対象は設定だけで、アカウントは含まない。**アクセストークンを平文 YAML に
/// 並べると、ファイル 1 つの流出で全アカウントが乗っ取られるため。インポート後に
/// アカウントを「未接続」として復元する話は #967 に分離した。
///
/// **端末固有の値も書かない**（[deviceLocalKeys]）。「書くがインポート時に無視」は、
/// ファイルに載っているのに反映されない混乱を生むので採らない。#952 で
/// 「その端末だけの値を複製すると壊れる」ことを実証したのと同型の判断。
library;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

/// ファイル形式の版。読み込み側は未知の版を弾く。
const settingsBackupFormatVersion = 1;

/// 設定値の型。SharedPreferences の格納型に対応する。
enum BackupValueType { boolean, number, text, textList }

/// バックアップ対象の設定 1 件。
class BackupSetting {
  const BackupSetting(this.key, this.type);

  /// SharedPreferences のキー。YAML 上のキーも同じものを使う（人が読んで
  /// どの設定か分かるようにするため、別名の対応表を持たない）。
  final String key;

  final BackupValueType type;
}

/// 書き出す設定 (#857)。
///
/// 追加した設定をここへ足し忘れると黙ってバックアップから漏れるため、
/// `test/settings_backup_coverage_test.dart` が
/// `preferences_provider.dart` のキー定義と突き合わせて検出する。
const exportableSettings = <BackupSetting>[
  // 表示
  BackupSetting('theme_mode', BackupValueType.text),
  BackupSetting('dark_surface_variant', BackupValueType.text),
  BackupSetting('dark_text_color', BackupValueType.text),
  BackupSetting('avatar_shape', BackupValueType.text),
  BackupSetting('font_scale', BackupValueType.number),
  BackupSetting('emoji_scale', BackupValueType.number),
  BackupSetting('thumbnail_scale', BackupValueType.number),
  BackupSetting('background_opacity', BackupValueType.number),
  BackupSetting('absolute_time', BackupValueType.boolean),
  BackupSetting('blur_all_images', BackupValueType.boolean),
  BackupSetting('hide_instance_ticker', BackupValueType.boolean),
  BackupSetting('hide_livecure', BackupValueType.boolean),
  BackupSetting('mfm_animation_enabled', BackupValueType.boolean),
  BackupSetting('emoji_zero_width_space', BackupValueType.boolean),
  BackupSetting('color_emoji_fallback', BackupValueType.boolean),
  BackupSetting('user_hover_popup', BackupValueType.boolean),
  BackupSetting('preview_card_mode', BackupValueType.text),
  BackupSetting('compose_font_family', BackupValueType.text),
  // 動作
  BackupSetting('restore_read_position', BackupValueType.boolean),
  BackupSetting('confirm_before_post', BackupValueType.boolean),
  BackupSetting('mouse_drag_scroll', BackupValueType.boolean),
  BackupSetting('streaming_enabled', BackupValueType.boolean),
  BackupSetting('show_stream_reconnect_detail', BackupValueType.boolean),
  BackupSetting('update_check_enabled', BackupValueType.boolean),
  BackupSetting('nowplaying_url_provider', BackupValueType.text),
  BackupSetting('post_touch_actions', BackupValueType.textList),
  // 履歴
  BackupSetting('recent_emojis', BackupValueType.textList),
  BackupSetting('compose_template_history', BackupValueType.textList),
];

/// **意図的に**書き出さない端末固有の設定 (#857)。
///
/// 新しい設定が増えたときに「対象に入れ忘れた」のか「意図的に外した」のかを
/// 区別できるよう、外した側も明示する。カバレッジテストがこの 2 つの和集合で
/// 突き合わせる。
const deviceLocalKeys = <String>{
  // ローカルファイルパス。他端末には存在しない。
  'background_image_path',
  // 画面サイズとキーボードに依存する。他端末へ持ち込む意味がない。
  'insert_picker_height',
  'reaction_picker_height',
  'sticker_picker_height',
  // OS 統合。端末ごとに決めるもの。
  'resident_mode',
  'launch_at_login',
};

/// 読み込み結果。
class SettingsImportResult {
  const SettingsImportResult({required this.applied, required this.skipped});

  /// 実際に書き込んだ設定のキー。
  final List<String> applied;

  /// ファイルにあったが取り込まなかったキーと理由。端末固有値・未知のキー・
  /// 型違いをここへ集め、画面で「何を無視したか」を出せるようにする。
  final Map<String, String> skipped;
}

/// 読み込めないファイルを渡されたときに投げる。
class SettingsBackupFormatException implements Exception {
  const SettingsBackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 現在の設定を YAML にする (#857)。
///
/// 未設定（既定値のまま）のキーは**書かない**。既定値を焼き込むと、後で既定が
/// 変わったときに古い既定値が復活してしまう。
String buildSettingsBackupYaml(
  SharedPreferences prefs, {
  required String appVersion,
  required String exportedAt,
}) {
  final buffer = StringBuffer()
    ..writeln('# capsicum の設定バックアップ')
    ..writeln('# アカウント・認証情報は含まれません。')
    ..writeln('version: $settingsBackupFormatVersion')
    ..writeln('app_version: ${_yamlString(appVersion)}')
    ..writeln('exported_at: ${_yamlString(exportedAt)}')
    ..writeln('settings:');

  var wrote = false;
  for (final setting in exportableSettings) {
    final value = _readValue(prefs, setting);
    if (value == null) continue;
    wrote = true;
    switch (setting.type) {
      case BackupValueType.textList:
        final list = value as List<String>;
        if (list.isEmpty) {
          buffer.writeln('  ${setting.key}: []');
        } else {
          buffer.writeln('  ${setting.key}:');
          for (final item in list) {
            buffer.writeln('    - ${_yamlString(item)}');
          }
        }
      case BackupValueType.text:
        buffer.writeln('  ${setting.key}: ${_yamlString(value as String)}');
      case BackupValueType.boolean:
      case BackupValueType.number:
        buffer.writeln('  ${setting.key}: $value');
    }
  }
  // 空マップは `settings:` だけになり YAML 上は null になる。読み込み側で
  // 「壊れたファイル」と区別できるよう明示的に空マップを書く。
  if (!wrote) {
    return buffer.toString().replaceFirst('settings:\n', 'settings: {}\n');
  }
  return buffer.toString();
}

/// YAML を読み込んで設定を書き戻す (#857)。
///
/// **知らないキー・型違い・端末固有キーは飛ばして続行する。**1 つの不整合で
/// 全体を捨てると、版をまたいだバックアップが丸ごと使えなくなる。
Future<SettingsImportResult> applySettingsBackupYaml(
  SharedPreferences prefs,
  String yamlText,
) async {
  final Object? parsed;
  try {
    parsed = loadYaml(yamlText);
  } on Exception catch (e) {
    throw SettingsBackupFormatException('ファイルを読み込めませんでした: $e');
  }
  if (parsed is! YamlMap) {
    throw const SettingsBackupFormatException('設定のバックアップファイルではありません');
  }
  final version = parsed['version'];
  if (version is! int) {
    throw const SettingsBackupFormatException('設定のバックアップファイルではありません');
  }
  if (version > settingsBackupFormatVersion) {
    throw SettingsBackupFormatException(
      'このファイルは新しい版の capsicum で書き出されています（版 $version）。'
      'capsicum を更新してから読み込んでください。',
    );
  }
  final settings = parsed['settings'];
  if (settings is! YamlMap) {
    throw const SettingsBackupFormatException('設定が入っていません');
  }

  final byKey = {for (final s in exportableSettings) s.key: s};
  final applied = <String>[];
  final skipped = <String, String>{};

  for (final entry in settings.nodes.entries) {
    final key = entry.key.toString();
    final value = entry.value.value;
    if (deviceLocalKeys.contains(key)) {
      skipped[key] = 'この端末固有の設定のため取り込みません';
      continue;
    }
    final setting = byKey[key];
    if (setting == null) {
      skipped[key] = '不明な設定です';
      continue;
    }
    if (!await _writeValue(prefs, setting, value)) {
      skipped[key] = '値の形式が設定と合いません';
      continue;
    }
    applied.add(key);
  }
  return SettingsImportResult(applied: applied, skipped: skipped);
}

Object? _readValue(SharedPreferences prefs, BackupSetting setting) =>
    switch (setting.type) {
      BackupValueType.boolean => prefs.getBool(setting.key),
      BackupValueType.number => prefs.getDouble(setting.key),
      BackupValueType.text => prefs.getString(setting.key),
      BackupValueType.textList => prefs.getStringList(setting.key),
    };

/// 型が合えば書き込んで true。合わなければ何もせず false。
Future<bool> _writeValue(
  SharedPreferences prefs,
  BackupSetting setting,
  Object? value,
) async {
  switch (setting.type) {
    case BackupValueType.boolean:
      if (value is! bool) return false;
      await prefs.setBool(setting.key, value);
    case BackupValueType.number:
      // YAML の `1` は int になる。整数で書かれた倍率を弾かない。
      if (value is! num) return false;
      await prefs.setDouble(setting.key, value.toDouble());
    case BackupValueType.text:
      if (value is! String) return false;
      await prefs.setString(setting.key, value);
    case BackupValueType.textList:
      if (value is! List) return false;
      if (value.any((e) => e is! String)) return false;
      await prefs.setStringList(setting.key, [
        for (final e in value) e as String,
      ]);
  }
  return true;
}

/// YAML の二重引用符スカラーとして書く。
///
/// 設定値にはフォント名・テンプレート履歴など任意の文字列が入りうるので、
/// 素の値をそのまま置かない（`:` や `#` を含むと壊れる）。
String _yamlString(String value) {
  final escaped = value
      .replaceAll('\\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return '"$escaped"';
}
