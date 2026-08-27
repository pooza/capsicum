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

/// 読み込むファイルの上限バイト数 (#1012)。
///
/// 実際の書き出しは数 KB で、アカウントを 100 件持っていても 10KB に届かない。
/// **「手で編集して壊したファイル」は通し、「別のファイルを選んだ」を弾く**線
/// として 1MiB を置く。ここを通さないと `readAsString` が端末のメモリを埋める。
const maxSettingsBackupBytes = 1024 * 1024;

/// フロースタイル (`[...]` / `{...}`) の入れ子の上限 (#1025)。
///
/// ⚠ **これは CPU 側の境界。**[maxSettingsBackupBytes] はメモリだけを見ており、
/// **1MiB に収まる範囲でパーサを何十秒も回せる**。`package:yaml` は再帰下降なので
/// 深さがそのまま時間に効き、実測（debug JIT）はこうなる。
///
/// | 深さ | サイズ | 経過 |
/// | --- | --- | --- |
/// | 5,000 | 10KB | 59ms |
/// | 50,000 | 100KB | 4,047ms |
/// | 200,000 | 400KB | 約 65,000ms |
///
/// フロースタイルは 1 段 2 バイト (`[` + `]`) なので、1MiB あれば 50 万段書ける。
/// **ブロックスタイルは 1 段ごとにインデントが伸びる**ので、同じ 1MiB でも
/// 深さは 1,500 段ほどが上限（実時間で数十 ms）。危ないのはフローだけ。
///
/// 実ファイルの深さは `settings` / `accounts` の 2〜3 段で、リスト値を数えても
/// 4〜5 段。32 は**実用の遥か上・病的の遥か下**に置いた線。
///
/// ⚠ **`compute()` で別 isolate へ出す案は採らなかった。**UI は固まらなくなるが、
/// **待ち時間は消えない**（数十秒 `_busy` のまま）。そもそも壊れたファイルなので、
/// 数 ms で理由を出して弾くほうが正しい。`YamlMap` を isolate 境界越しに返す
/// リスクも負わずに済む。
const maxSettingsBackupNestingDepth = 32;

/// 索引へ取り込むアカウントの上限 (#1012)。
///
/// プリセット 5 + 手元のサーバーを足しても 2 桁に届かない。手編集や別ファイルで
/// 巨大な `accounts:` が来たときに、SharedPreferences の索引を膨らませない。
/// ⚠ **超えたら黙って切り詰めず、丸ごと取り込まない**（どれが落ちたか分からない
/// 索引を作るより、理由を出して何もしないほうがユーザーは次の手を選べる）。
const maxBackupAccounts = 200;

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
/// ⚠ **host / username の欠けは parse では落ちない（Codex P2 / PR #1002）。**
/// `AccountKey.fromStorageKey` は `Uri.parse` に乗っているだけなので、
/// `mastodon://alice` は host=`alice` / username=`` として通り、正規形は
/// `mastodon://@alice` になる。そのまま索引へ入れると、**復帰できない未接続の行**
/// を作ったうえで「アカウントを追加しました」と報告してしまう。両方が揃って
/// いることを確かめる。
String? _canonicalAccountKey(String key) {
  try {
    final parsed = AccountKey.fromStorageKey(key);
    if (parsed.host.isEmpty || parsed.username.isEmpty) return null;

    return parsed.toStorageKey();
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

/// フロースタイルの入れ子が [maxSettingsBackupNestingDepth] を超えるか (#1025)。
///
/// パースせずに 1 パスで数える。**壊れたファイルを弾くための安価な門番**であって、
/// YAML の妥当性検査ではない。閉じ括弧の対応も見ない（超えたかどうかだけ分かれば
/// よく、不整合な括弧は後段の `loadYaml` が弾く）。
///
/// 引用符とコメントは飛ばす。⚠ **ここを省くと、本文に `[` を含む設定値
/// （投稿テンプレート等）が深さに数えられて、正しいファイルを誤って弾く。**
/// 逆に飛ばしすぎても、閾値 32 まで届く括弧列を持つ実ファイルは無いので安全側。
///
/// ⚠ **ブロックスタイルは数えない。**1 段ごとにインデントが伸びるため
/// [maxSettingsBackupBytes] が実質的な上限になっており、そこまで深くしても
/// 実時間は数十 ms に収まる（[maxSettingsBackupNestingDepth] の doc 参照）。
bool exceedsSettingsBackupNestingDepth(String yamlText) {
  var depth = 0;
  for (var i = 0; i < yamlText.length; i++) {
    final c = yamlText[i];
    switch (c) {
      case '#':
        // コメントは行末まで。YAML では行頭か空白の後ろだけがコメント開始だが、
        // ここでは括弧を数えないことだけが目的なので厳密さは要らない。
        while (i < yamlText.length && yamlText[i] != '\n') {
          i++;
        }
      case "'":
        // 単一引用スカラー。'' が閉じない形のエスケープ。
        i++;
        while (i < yamlText.length) {
          if (yamlText[i] != "'") {
            i++;
            continue;
          }
          if (i + 1 < yamlText.length && yamlText[i + 1] == "'") {
            i += 2;
            continue;
          }
          break;
        }
      case '"':
        // 二重引用スカラー。\ でエスケープ。
        i++;
        while (i < yamlText.length && yamlText[i] != '"') {
          if (yamlText[i] == r'\') i++;
          i++;
        }
      case '[':
      case '{':
        depth++;
        if (depth > maxSettingsBackupNestingDepth) return true;
      case ']':
      case '}':
        if (depth > 0) depth--;
    }
  }
  return false;
}

/// YAML を読み込んで設定を書き戻す (#857)。
///
/// **知らないキー・型違い・端末固有キーは飛ばして続行する。**1 つの不整合で
/// 全体を捨てると、版をまたいだバックアップが丸ごと使えなくなる。
///
/// [accountStorage] は索引へ書き戻す key の残骸 secret を消すためだけに使う
/// （[AccountStorage.purgeStaleSecrets]）。省略時は実物を使う — **取り込み口が
/// 設定画面とログイン前の 2 つある**ので、呼び出し側に任せると片方だけ守られる
/// （#996 が繰り返し踏んだ「母数の取りこぼし」）。
Future<SettingsImportResult> applySettingsBackupYaml(
  SharedPreferences prefs,
  String yamlText, {
  AccountStorage? accountStorage,
}) async {
  // ⚠ **パースの前に深さを見る (#1025)。**ここを通してしまうと、例外を捕まえる
  // 前にメイン isolate が数十秒（実測で最大 65 秒）同期的に回る。Android は
  // ANR、iOS はウォッチドッグの射程。
  //
  // ⚠ **`readSettingsBackupFile` ではなくここに置く。**取り込み口は設定画面と
  // サーバー選択画面の 2 つあり、さらに将来ファイル以外から YAML が来ても
  // ここを通る。手前に置くと、その都度「両方に入れたか」を数え直すことになる。
  if (exceedsSettingsBackupNestingDepth(yamlText)) {
    throw const SettingsBackupFormatException('ファイルの構造が深すぎて読み込めませんでした');
  }

  final Object? parsed;
  try {
    parsed = loadYaml(yamlText);
  } on Exception catch (e) {
    throw SettingsBackupFormatException('ファイルを読み込めませんでした: $e');
  } on StackOverflowError {
    // ⚠ **`Error` なので `on Exception` を素通りする (#1012)。**深くネストした
    // YAML（`[[[[...]]]]`）で再帰下降パーサが刺さる。素通りすると呼び出し側の
    // 汎用 catch へ落ち、ユーザーの選択ミスが error レベルの観測になる。
    // ⚠ alias 爆弾は展開しない（`package:yaml` がノードを共有するため・実測済み）。
    throw const SettingsBackupFormatException('ファイルの構造が深すぎて読み込めませんでした');
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
    accountStorage ?? AccountStorage(),
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
/// ⚠ **secret は増やさない。**索引だけが増えるので、足したアカウントは
/// 「未接続」として並ぶ（#967）。ログインし直すとトークンが入って復帰する。
///
/// ⚠⚠ **ただし「触らない」では不変条件が成り立たない (#1012)。**
/// [AccountStorage.removeAccount] は secret の delete に失敗しても索引を消すの
/// で、削除前のバックアップを取り込むと**索引だけが復活して残骸トークンと再会
/// する**。次回起動の `restoreSessions` がそれで probe に成功し、削除したはずの
/// アカウントが完全ログイン状態で戻る。書き戻す key の残骸は
/// [AccountStorage.purgeStaleSecrets] で必ず消す。
///
/// 壊れた要素は黙って捨てず [skipped] に理由を積む。ファイル全体を捨てないのは
/// 設定側と同じ方針。
Future<List<String>> _mergeAccounts(
  SharedPreferences prefs,
  Object? node,
  Map<String, String> skipped,
  AccountStorage accountStorage,
) async {
  if (node == null) return const [];
  if (node is! YamlList) {
    skipped['accounts'] = 'アカウントの一覧が読めませんでした';
    return const [];
  }
  if (node.length > maxBackupAccounts) {
    skipped['accounts'] = 'アカウントの一覧が多すぎます（$maxBackupAccounts 件まで）。取り込みませんでした';
    return const [];
  }

  final existing = readAccountKeysForBackup(prefs);
  final merged = [...existing];
  // ⚠ **突き合わせは正規形どうしで (#1011)。**取り込む側は正規形なのに、索引側は
  // 生のまま（`readAccountKeysForBackup` は parse できるかを見るだけ）だったので、
  // 索引に非正規形が入っている端末では `contains` が外れて**同じアカウントが 2 行
  // に割れる**。ホストを大文字混じりで打って作ったアカウントで踏む。
  // ⚠ **索引そのものは直さない。**`secret_<key>` は生の key で引くので、ここで
  // 書き換えるとトークンとの対応が切れる。比較用の集合だけ正規形にする。
  final canonical = existing
      .map(_canonicalAccountKey)
      .whereType<String>()
      .toSet();
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
    if (!canonical.add(key)) continue;
    merged.add(key);
    added.add(key);
  }
  final reasons = <String>[if (invalid > 0) '$invalid 件のアカウントを読み取れませんでした'];
  if (added.isEmpty) {
    if (reasons.isNotEmpty) skipped['accounts'] = reasons.join(' / ');
    return const [];
  }

  // ⚠ **索引を書く前に残骸を消す (#1012)。** 順序を逆にすると、purge が落ちた
  // 瞬間に「索引はあるが残骸トークンも生きている」状態が残る。
  //
  // ⚠⚠ **消しきれなかったアカウントは書き戻さない。** #621 の非 op delete は
  // まさにここで空振りするので、構わず索引を書くと**この修正が塞ごうとして
  // いる状態がそのまま完成する**。取り込めなかったことは理由つきで返し、
  // ユーザーには「ログインし直す」という手が残る（索引が無くても
  // 「アカウントを追加」から入れる）。
  final unresolved = (await accountStorage.purgeStaleSecrets(added)).toSet();
  if (unresolved.isNotEmpty) {
    added.removeWhere(unresolved.contains);
    merged.removeWhere(unresolved.contains);
    // ⚠ **「残っている」と言い切らない (#1020)。**secure storage を確認でき
    // なかったぶんもここへ来る（plugin 未登録＝register race）。断定すると、
    // 実際には残骸が無い端末で「古い認証情報が残っている」と嘘を伝える。
    reasons.add(
      '${unresolved.length} 件のアカウントは、この端末に古い認証情報が残っている'
      'か確認できなかったため取り込みませんでした',
    );
  }
  if (reasons.isNotEmpty) skipped['accounts'] = reasons.join(' / ');
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
///
/// ⚠ **setter の戻り値を捨てない（v1.60 リリース前レビュー）。**`SharedPreferences`
/// の setter は失敗しても throw せず `false` を返す。捨てると `applied` に積まれ、
/// 画面には「N 件の設定を読み込みました」が出るのに再起動すると元のまま、という
/// 無言の部分失敗になる。同じ罠を [_mergeAccounts] は潰してあるのに、設定本体
/// だけが素通しだった。
Future<String?> _writeValue(
  SharedPreferences prefs,
  BackupSetting setting,
  Object? value,
) async {
  const typeMismatch = '値の形式が設定と合いません';
  const writeFailed = '設定を保存できませんでした';
  switch (setting.type) {
    case BackupValueType.boolean:
      if (value is! bool) return typeMismatch;
      if (!await prefs.setBool(setting.key, value)) return writeFailed;
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
      if (!await prefs.setDouble(setting.key, number)) return writeFailed;
    case BackupValueType.text:
      if (value is! String) return typeMismatch;
      if (!await prefs.setString(setting.key, value)) return writeFailed;
    case BackupValueType.textList:
      if (value is! List) return typeMismatch;
      if (value.any((e) => e is! String)) return typeMismatch;
      final ok = await prefs.setStringList(setting.key, [
        for (final e in value) e as String,
      ]);
      if (!ok) return writeFailed;
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
