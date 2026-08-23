import 'dart:io';

import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/settings_backup.dart';
import 'package:capsicum/src/ui/util/settings_backup_apply.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1012: 取り込みの入力に上限を置く。
///
/// ⚠ **「YAML を選ぶ」導線は、任意のファイルを選べる導線でもある。** iOS の UTI
/// は `public.data`（`settings_backup_file_type.dart` の doc）で、Android の
/// mimeTypes 絞り込みも提供側次第。動画を選ばれると、内容を見る前に端末の
/// メモリへ丸ごと載る。
///
/// ⚠ **`StackOverflowError` は `Error` なので `on Exception` を素通りする。**
/// 深くネストした YAML で再帰下降パーサが刺さると、呼び出し側の汎用 catch へ
/// 落ちて**ユーザーの選択ミスが error レベルの観測になる**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> emptyPrefs() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  group('ファイルサイズの上限', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('capsicum_backup'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('大きすぎるファイルは読まずに弾く', () async {
      final file = File('${dir.path}/huge.yaml')
        ..writeAsBytesSync(List.filled(maxSettingsBackupBytes + 1, 0x41));

      await expectLater(
        readSettingsBackupFile(XFile(file.path)),
        throwsA(isA<SettingsBackupFormatException>()),
      );
    });

    // ⚠ **format 例外にすること。**ユーザーの選択ミスであって障害ではないので、
    // 呼び出し側の汎用 catch（error レベル）ではなく件数だけ数える方へ落とす。
    test('上限ちょうどは通す', () async {
      final file = File('${dir.path}/ok.yaml')
        ..writeAsStringSync('version: 1\nsettings: {}\n');

      expect(
        await readSettingsBackupFile(XFile(file.path)),
        contains('version'),
      );
    });
  });

  group('YAML の構造', () {
    test('深くネストしたファイルは format 例外にする（StackOverflowError を漏らさない）', () async {
      final prefs = await emptyPrefs();
      const depth = 200000;
      final bomb = '${'[' * depth}${']' * depth}';

      await expectLater(
        applySettingsBackupYaml(prefs, 'version: 1\nsettings: $bomb\n'),
        throwsA(isA<SettingsBackupFormatException>()),
      );
    });
  });

  group('アカウント件数の上限', () {
    String yamlWithAccounts(int count) {
      final lines = [
        for (var i = 0; i < count; i++) '  - mastodon://u$i@example.test',
      ];
      return 'version: 1\naccounts:\n${lines.join('\n')}\nsettings: {}\n';
    }

    test('上限を超えたら 1 件も取り込まない', () async {
      final prefs = await emptyPrefs();

      final result = await applySettingsBackupYaml(
        prefs,
        yamlWithAccounts(maxBackupAccounts + 1),
      );

      expect(result.addedAccountKeys, isEmpty);
      expect(
        prefs.getString(AccountStorage.accountListKey),
        isNull,
        reason: '黙って切り詰めると、どれが落ちたか分からない索引ができる',
      );
      expect(result.skipped['accounts'], isNotNull, reason: '理由は返す');
    });

    test('上限ちょうどは取り込む', () async {
      final prefs = await emptyPrefs();

      // ⚠ **secure storage を渡すこと。**渡さないと plugin 未登録で
      // `purgeStaleSecrets` が「確認できなかった」を返し、#1020 の fail-closed
      // で 1 件も入らない。この検査の主題は件数の上限なので、残骸は無い状態を
      // 与える。
      final result = await applySettingsBackupYaml(
        prefs,
        yamlWithAccounts(maxBackupAccounts),
        accountStorage: AccountStorage(_NoSecretsStorage()),
      );

      expect(result.addedAccountKeys, hasLength(maxBackupAccounts));
    });
  });

  /// ⚠ **「値は載せない」だけでは足りない。** 未知のキーは YAML のマッピング
  /// キーそのもの＝ファイル由来の任意文字列で、手編集されたバックアップなら
  /// ユーザーが書いた何でも入る。doc は「値は含めない」と宣言していたのに、
  /// キー名の側から素通しになっていた。
  group('Sentry へ載せる skip の伏せ字', () {
    test('知っているキーはそのまま、知らないキーは件数へ丸める', () {
      final redacted = redactSkippedKeysForReport({
        'font_scale': '範囲外です',
        'background_image_path': 'この端末固有の設定のため取り込みません',
        'accounts': '1 件のアカウントを読み取れませんでした',
        'ユーザーが書いた秘密のメモ': '不明な設定です',
        'another-unknown-key': '不明な設定です',
      });

      expect(redacted['font_scale'], '範囲外です');
      expect(redacted['background_image_path'], isNotNull);
      expect(redacted['accounts'], isNotNull);
      expect(redacted['(unknown)'], 2);
      expect(
        redacted.keys,
        isNot(contains('ユーザーが書いた秘密のメモ')),
        reason: 'キー名の側からファイルの中身が漏れていた',
      );
    });

    // 壊れたファイルは未知キーを大量に持ちうる。context が肥大して Sentry 側で
    // 切り捨てられると、全部見えなくなる。
    test('件数にも上限があり、落としたぶんは数で残る', () {
      final redacted = redactSkippedKeysForReport({
        for (final setting in exportableSettings) setting.key: '不明な設定です',
      });

      final reported = redacted.keys.where((k) => !k.startsWith('(')).length;
      expect(reported, lessThanOrEqualTo(30));
      if (exportableSettings.length > 30) {
        expect(redacted['(truncated)'], exportableSettings.length - 30);
      }
    });

    test('何も落ちていなければ空', () {
      expect(redactSkippedKeysForReport({}), isEmpty);
    });
  });
}

/// 残骸トークンが 1 つも無い secure storage。`purgeStaleSecrets` を素通りさせる
/// ためだけの器で、残骸の扱いそのものは `settings_backup_stale_secret_test.dart`
/// が見る。
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
