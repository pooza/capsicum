/// 設定のバックアップ（書き出し / 読み込み）(#857 / #1001)。
///
/// **アクセストークンは含まない。**平文 YAML に並べると、ファイル 1 つの流出で
/// 全アカウントが乗っ取られるため。⚠ **だからこそ「再接続」が要る** — 移行先へ
/// 持っていくのは**アカウント索引（host + username）だけ**で、トークンの無い
/// アカウントは「未接続」として一覧に並び、ログインし直すとトークンが再設定
/// されて復帰する（#967）。索引と再接続で 1 つの筋書きなので、片方だけでは
/// 「スマホと PC でアカウントを同期する」は成立しない。
///
/// **端末固有の値は書かない**（[deviceLocalKeys]）。「書くがインポート時に無視」は、
/// ファイルに載っているのに反映されない混乱を生むので採らない。#952 で
/// 「その端末だけの値を複製すると壊れる」ことを実証したのと同型の判断。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

import '../model/account_key.dart';
import 'account_storage.dart';

/// ファイル形式の版。読み込み側は未知の版を弾く。
const settingsBackupFormatVersion = 1;

/// 設定値の型。SharedPreferences の格納型に対応する。
enum BackupValueType { boolean, number, text, textList }

/// バックアップ対象の設定 1 件。
class BackupSetting {
  const BackupSetting(this.key, this.type, {this.min, this.max});

  /// SharedPreferences のキー。YAML 上のキーも同じものを使う（人が読んで
  /// どの設定か分かるようにするため、別名の対応表を持たない）。
  final String key;

  final BackupValueType type;

  /// [BackupValueType.number] の許容範囲。**読み込み側の最後の砦**。
  ///
  /// 「SharedPreferences に入っている数値は必ず範囲内」という不変条件は、
  /// これまで setter の clamp **だけ**が守っていた（`FontScaleNotifier._load`
  /// 等の読み手は保存値を無検査で state に入れる）。そこへ範囲を見ない第 2 の
  /// 書き手を足すと不変条件が壊れる。バックアップは平文 YAML でキー名も
  /// そのまま＝**手編集が想定内**なので、`1.4` を `14` と打ち間違えるだけで
  /// 全テキストが 14 倍になり、設定画面（「既定に戻す」を含む）へ戻れなくなる。
  /// 値は永続化されるので再起動しても直らず、復旧手段は再インストールしかない。
  ///
  /// 値は `preferences_provider.dart` の `min*` / `max*` と一致させること。
  /// ずれの検出は `test/settings_backup_range_test.dart` が担当する
  /// （こちらを純粋な service に保つため、provider を import しない）。
  final double? min;
  final double? max;
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
  BackupSetting('font_scale', BackupValueType.number, min: 0.8, max: 1.4),
  BackupSetting('emoji_scale', BackupValueType.number, min: 16, max: 40),
  BackupSetting('thumbnail_scale', BackupValueType.number, min: 0.4, max: 1.2),
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

/// **意図的に**書き出さない、アカウントごとの設定 (#857)。
///
/// アカウントを含まないバックアップ（冒頭 doc）では復元先が決まらないため、
/// 端末固有値と同じく対象外にする。[deviceLocalKeys] と分けているのは、外した
/// 理由が違う（あちらは「他端末に存在しない」、こちらは「どのアカウントへ
/// 入れるか決められない」）ため。アカウントごと復元する話は #967。
///
/// `background_opacity` は実際の保存先が `background_opacity_<アカウント>` で、
/// 素のキーは旧版から移行するためだけに読まれる（`setOpacity` は二度と書か
/// ない）。ここへ入れる前は [exportableSettings] にいたが、**書き出しは常に
/// 空振りし、読み込みは移行キーへ書くので per-account 値をまだ持たない全
/// アカウントへ染み出す**という壊れ方をしていた。名前が同じでも実体が別キー
/// なら対象にできない。
const accountScopedKeys = <String>{
  'background_opacity',
  // 以下はアカウント別設定の **プレフィックス**（実体は `<prefix><アカウント>`）。
  // preferences_provider.dart に `_…Prefix` として定義され、素のプレフィックスが
  // 保存キーになることはない。どのアカウントへ復元するか決められないため対象外で、
  // アカウント込みの復元は #967。カバレッジ検査 (settings_backup_coverage_test) が
  // `_…Prefix` も拾うようになったので、`background_opacity` と同じく「意図的な除外」
  // として明示する（列挙漏れを黙って通さないため）。
  'theme_color_',
  'tab_order_',
  'last_tab_',
  'emoji_palette_',
  'emoji_reaction_palette_',
  'pinned_hashtags_',
  'hidden_list_ids_',
  'list_order_',
  'hidden_timeline_types_',
  'tab_config_',
};

/// 読み込み結果。
class SettingsImportResult {
  const SettingsImportResult({
    required this.applied,
    required this.skipped,
    this.addedAccountKeys = const [],
  });

  /// 実際に書き込んだ設定のキー。
  final List<String> applied;

  /// ファイルにあったが取り込まなかったキーと理由。端末固有値・未知のキー・
  /// 型違いをここへ集め、画面で「何を無視したか」を出せるようにする。
  final Map<String, String> skipped;

  /// 索引へ新しく足したアカウントの storage key (#1001)。**トークンは入って
  /// いない**ので、これらは「未接続」として一覧に並ぶ（#967）。
  ///
  /// ⚠ **件数だけでなく key を返す。**呼び出し側が実行中の一覧へ反映する
  /// （[AccountManagerNotifier.addDisconnectedAccounts]）ために要る。件数だけだと
  /// 「追加しました」と言いながら次の起動まで画面に出ない。
  final List<String> addedAccountKeys;
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
/// バックアップの `accounts:` に載せるアカウント索引を読む (#1001)。
///
/// 値は `AccountKey.toStorageKey()`（`mastodon://user@host`）の JSON 配列で、
/// **host + username だけを持つ非秘匿値**（`AccountStorage` の doc 参照。だから
/// SharedPreferences に置いている）。⚠ **secret は載せない。**平文 YAML に
/// トークンが並ぶと、ファイル 1 つの流出で全アカウントが乗っ取られる（#857 で
/// 確定した方針）。移行先ではトークンが無いので「未接続」として並び、ログイン
/// し直すと復帰する（#967）。
List<String> readAccountKeysForBackup(SharedPreferences prefs) {
  final encoded = prefs.getString(AccountStorage.accountListKey);
  if (encoded == null) return const [];
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! List) return const [];
    return decoded.whereType<String>().where(_isParsableAccountKey).toList();
  } catch (_) {
    // 索引の JSON 破損。書き出し側で拾っても直せないので黙って空にする
    // （AccountStorage.getAccountKeys も同じ扱い）。
    return const [];
  }
}

/// storage key を**正規形**に直す。読めなければ null (#1001)。
///
/// ⚠ **正規化せずに保存すると同じアカウントが 2 行に割れる**（Codex P2 /
/// PR #1002）。手で編集したバックアップに `mastodon://alice@example.com/` のような
/// 非正規形が入っていると、parse は通るのに `toStorageKey()` とは別文字列なので、
/// 接続し直した後に `saveAccount` が正規形を**別のアカウントとして**足す。次の
/// 起動で「トークンのある行」と「未接続の行」が同じアカウントに対して並ぶ。
String? _canonicalAccountKey(String key) {
  try {
    return AccountKey.fromStorageKey(key).toStorageKey();
  } catch (_) {
    return null;
  }
}

bool _isParsableAccountKey(String key) => _canonicalAccountKey(key) != null;

void _writeAccounts(StringBuffer buffer, SharedPreferences prefs) {
  final keys = readAccountKeysForBackup(prefs);
  if (keys.isEmpty) return;

  buffer.writeln('accounts:');
  for (final key in keys) {
    buffer.writeln('  - ${_yamlString(key)}');
  }
}

/// 未設定（既定値のまま）のキーは**書かない**。既定値を焼き込むと、後で既定が
/// 変わったときに古い既定値が復活してしまう。
String buildSettingsBackupYaml(
  SharedPreferences prefs, {
  required String appVersion,
  required String exportedAt,
}) {
  final buffer = StringBuffer()
    ..writeln('# capsicum の設定バックアップ')
    ..writeln('# アカウントの一覧（サーバーとユーザー名）を含みます。')
    ..writeln('# パスワードとアクセストークンは含まれません。')
    ..writeln('version: $settingsBackupFormatVersion')
    ..writeln('app_version: ${_yamlString(appVersion)}')
    ..writeln('exported_at: ${_yamlString(exportedAt)}');

  _writeAccounts(buffer, prefs);
  buffer.writeln('settings:');

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
  final addedAccountKeys = await _mergeAccounts(
    prefs,
    parsed['accounts'],
    skipped,
  );

  for (final entry in settings.nodes.entries) {
    final key = entry.key.toString();
    final value = entry.value.value;
    if (deviceLocalKeys.contains(key)) {
      skipped[key] = 'この端末固有の設定のため取り込みません';
      continue;
    }
    if (accountScopedKeys.contains(key)) {
      skipped[key] = 'アカウントごとの設定のため取り込みません';
      continue;
    }
    final setting = byKey[key];
    if (setting == null) {
      skipped[key] = '不明な設定です';
      continue;
    }
    final rejected = await _writeValue(prefs, setting, value);
    if (rejected != null) {
      skipped[key] = rejected;
      continue;
    }
    applied.add(key);
  }
  return SettingsImportResult(
    applied: applied,
    skipped: skipped,
    addedAccountKeys: addedAccountKeys,
  );
}

/// バックアップの `accounts:` を索引へ**マージ**する (#1001)。返り値は新しく
/// 足したアカウントの storage key。
///
/// ⚠ **既存のアカウントを消さない。**移行先に既にアカウントが居ることがあり、
/// 置き換えると「読み込んだら手元のアカウントが消えた」になる。既にある key は
/// 何もしない（重複させない）。
///
/// ⚠ **secret は触らない。**索引だけが増えるので、足したアカウントは
/// 「未接続」として並ぶ（#967）。ログインし直すとトークンが入って復帰する。
///
/// 壊れた要素は黙って捨てず [skipped] に理由を積む。ファイル全体を捨てないのは
/// 設定側と同じ方針。
Future<List<String>> _mergeAccounts(
  SharedPreferences prefs,
  Object? node,
  Map<String, String> skipped,
) async {
  if (node == null) return const [];
  if (node is! YamlList) {
    skipped['accounts'] = 'アカウントの一覧が読めませんでした';
    return const [];
  }

  final existing = readAccountKeysForBackup(prefs);
  final merged = [...existing];
  final added = <String>[];
  var invalid = 0;
  for (final entry in node) {
    // ⚠ **正規形にしてから入れる。**非正規形のまま保存すると、接続し直した後に
    // 同じアカウントが 2 行（トークンあり / 未接続）に割れる。
    final key = entry is String ? _canonicalAccountKey(entry) : null;
    if (key == null) {
      invalid++;
      continue;
    }
    if (merged.contains(key)) continue;
    merged.add(key);
    added.add(key);
  }
  if (invalid > 0) {
    skipped['accounts'] = '$invalid 件のアカウントを読み取れませんでした';
  }
  if (added.isEmpty) return const [];

  // ⚠ setString は失敗しても throw せず false を返す（AccountStorage と同じ罠）。
  // 失敗を成功として報告すると「読み込んだのに増えていない」が無言になる。
  final ok = await prefs.setString(
    AccountStorage.accountListKey,
    jsonEncode(merged),
  );
  if (!ok) {
    skipped['accounts'] = 'アカウントの一覧を保存できませんでした';
    return const [];
  }
  return added;
}

Object? _readValue(SharedPreferences prefs, BackupSetting setting) =>
    switch (setting.type) {
      BackupValueType.boolean => prefs.getBool(setting.key),
      BackupValueType.number => prefs.getDouble(setting.key),
      BackupValueType.text => prefs.getString(setting.key),
      BackupValueType.textList => prefs.getStringList(setting.key),
    };

/// 書き込めたら null。書き込まなかったときは [SettingsImportResult.skipped] へ
/// 載せる理由を返す。
Future<String?> _writeValue(
  SharedPreferences prefs,
  BackupSetting setting,
  Object? value,
) async {
  const typeMismatch = '値の形式が設定と合いません';
  switch (setting.type) {
    case BackupValueType.boolean:
      if (value is! bool) return typeMismatch;
      await prefs.setBool(setting.key, value);
    case BackupValueType.number:
      // YAML の `1` は int になる。整数で書かれた倍率を弾かない。
      if (value is! num) return typeMismatch;
      final number = value.toDouble();
      // YAML の `.nan` / `.inf` は double として通る。NaN は大小比較が
      // どちらも false になり範囲チェックをすり抜けるので、先に落とす。
      if (!number.isFinite) return typeMismatch;
      final min = setting.min;
      final max = setting.max;
      if ((min != null && number < min) || (max != null && number > max)) {
        return '設定できる範囲（$min〜$max）を外れています';
      }
      await prefs.setDouble(setting.key, number);
    case BackupValueType.text:
      if (value is! String) return typeMismatch;
      await prefs.setString(setting.key, value);
    case BackupValueType.textList:
      if (value is! List) return typeMismatch;
      if (value.any((e) => e is! String)) return typeMismatch;
      await prefs.setStringList(setting.key, [
        for (final e in value) e as String,
      ]);
  }
  return null;
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
