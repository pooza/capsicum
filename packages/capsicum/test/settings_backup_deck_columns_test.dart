import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/settings_backup.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1101: デッキのカラム列をバックアップに含める。
///
/// ⚠⚠ **単独では決められない Issue だった。**カラム列はタブ設定の一般化
/// （`docs/deck-ui-plan.md` 決定済み事項 6-1）なので、**タブ設定が移らないのに
/// カラム列だけ移る**という非対称を作れない。#1119 でアカウント別設定が
/// バックアップ対象になった（v1.65 出荷）ので、その上に乗せる。
///
/// ⚠⚠ **落とし方は「既存の『未接続アカウント』に吸収する」**（未決事項 5-1）。
/// 索引にあるアカウントは、トークンが無くても一覧に並ぶ（#967 / #1001）ので、
/// **そのアカウントを指すカラムは残してよい** —— ログインし直すと動き出す。
/// **プレースホルダという新しい概念を発明しない**のが決着の要点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const alice = 'mastodon://alice@mstdn.example';
  const bob = 'misskey://bob@misskey.example';

  String column(String id, String account, String tab) => '$id|$account|$tab';

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  String yamlOf(SharedPreferences prefs) => buildSettingsBackupYaml(
    prefs,
    appVersion: '2.0.0+186',
    exportedAt: '2026-09-20T12:00:00Z',
  );

  /// ⚠ secure storage を渡す理由は `settings_backup_account_settings_test` と同じ
  /// （渡さないと `purgeStaleSecrets` が fail-closed で索引に 1 件も入らない）。
  Future<SettingsImportResult> apply(SharedPreferences prefs, String yaml) =>
      applySettingsBackupYaml(
        prefs,
        yaml,
        accountStorage: AccountStorage(_NoSecretsStorage()),
      );

  /// 取り込み先の端末。索引に [accounts] を持つ。
  Future<SharedPreferences> targetWith(
    List<String> accounts, {
    List<String>? deck,
  }) => prefsWith(<String, Object>{
    'capsicum_account_keys_v2': '[${accounts.map((a) => '"$a"').join(',')}]',
    deckColumnsBackupKey: ?deck,
  });

  group('書き出し', () {
    test('索引にあるアカウントのカラムを deck_columns へ書く', () async {
      final prefs = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        deckColumnsBackupKey: [
          column('c1', alice, 'timeline:home'),
          column('c2', alice, 'hashtag:precure_fun'),
        ],
      });

      final yaml = yamlOf(prefs);

      expect(yaml, contains('deck_columns:'));
      expect(yaml, contains('  - "c1|$alice|timeline:home"'));
      expect(yaml, contains('  - "c2|$alice|hashtag:precure_fun"'));
    });

    test('⚠ 索引に無いアカウントを指すカラムは書かない（accounts と食い違わせない）', () async {
      final prefs = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        deckColumnsBackupKey: [
          column('c1', alice, 'timeline:home'),
          column('c2', bob, 'timeline:home'),
        ],
      });

      final yaml = yamlOf(prefs);

      expect(yaml, contains('c1|$alice'));
      expect(yaml, isNot(contains(bob)));
    });

    test('⚠ 読めない行は書かない（旧版・手編集・未知の種別）', () async {
      final prefs = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        deckColumnsBackupKey: [
          column('c1', alice, 'timeline:home'),
          'こわれた行',
          column('c3', alice, 'future_tab:99'),
        ],
      });

      final yaml = yamlOf(prefs);

      expect(yaml, contains('c1|$alice'));
      expect(yaml, isNot(contains('こわれた行')));
      expect(yaml, isNot(contains('future_tab')));
    });

    test('カラムが 1 本も無ければ節を書かない', () async {
      final prefs = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        'font_scale': 1.2,
      });

      expect(yamlOf(prefs), isNot(contains('deck_columns:')));
    });
  });

  group('読み込み', () {
    test('カラム列を取り込む', () async {
      final source = await prefsWith({
        'capsicum_account_keys_v2': '["$alice"]',
        deckColumnsBackupKey: [
          column('c1', alice, 'timeline:home'),
          column('c2', alice, 'list:7'),
        ],
      });
      final yaml = yamlOf(source);

      final target = await targetWith([alice]);
      final result = await apply(target, yaml);

      expect(target.getStringList(deckColumnsBackupKey), [
        column('c1', alice, 'timeline:home'),
        column('c2', alice, 'list:7'),
      ]);
      expect(result.applied, contains(deckColumnsBackupKey));
      expect(result.skipped, isNot(contains(deckColumnsBackupKey)));
    });

    test('⚠⚠ 索引にある（＝未接続の）アカウントを指すカラムは残す', () async {
      // 移行直後の端末。索引にはアカウントが並ぶが、トークンはまだ無い（#967）。
      // ここでカラムを捨てると、ログインし直しても列が戻らない。
      final yaml =
          '''
version: 1
accounts:
  - "$alice"
deck_columns:
  - "${column('c1', alice, 'timeline:home')}"
settings: {}
''';

      // 取り込み先は索引が空（＝このファイルで初めてアカウントを知る）。
      final target = await prefsWith(<String, Object>{});
      final result = await apply(target, yaml);

      expect(
        target.getStringList(deckColumnsBackupKey),
        [column('c1', alice, 'timeline:home')],
        reason: 'このファイルで足したアカウントのカラムも取り込む',
      );
      expect(result.skipped, isNot(contains(deckColumnsBackupKey)));
    });

    test('⚠ 索引にも無いアカウントのカラムは取り込まず、件数を出す', () async {
      final yaml =
          '''
version: 1
accounts:
  - "$alice"
deck_columns:
  - "${column('c1', alice, 'timeline:home')}"
  - "${column('c2', bob, 'timeline:home')}"
settings: {}
''';

      final target = await targetWith([alice]);
      final result = await apply(target, yaml);

      expect(target.getStringList(deckColumnsBackupKey), [
        column('c1', alice, 'timeline:home'),
      ]);
      // ⚠ 黙って捨てない。理由は件数だけ（アカウント名＝ファイル由来の文字列を
      // `skipped` のキーにしない）。
      expect(result.skipped[deckColumnsBackupKey], contains('1 件'));
      expect(
        result.skipped.keys,
        isNot(contains(bob)),
        reason: 'ファイル由来の文字列を skipped のキーにしない (#1012)',
      );
    });

    test('⚠⚠ 1 本も残らなければ、手元のカラム列を消さない', () async {
      final yaml =
          '''
version: 1
accounts:
  - "$alice"
deck_columns:
  - "${column('c1', bob, 'timeline:home')}"
settings: {}
''';

      final target = await targetWith(
        [alice],
        deck: [column('mine', alice, 'timeline:home')],
      );
      final result = await apply(target, yaml);

      expect(
        target.getStringList(deckColumnsBackupKey),
        [column('mine', alice, 'timeline:home')],
        reason: '「取り込んだら自分のデッキが消えた」にしない',
      );
      expect(result.skipped[deckColumnsBackupKey], isNotNull);
      expect(result.applied, isNot(contains(deckColumnsBackupKey)));
    });

    test('⚠ 上限を超えたら丸ごと取り込まない（手編集への防御）', () async {
      final many = [
        for (var i = 0; i <= maxBackupDeckColumns; i++)
          '  - "${column('c$i', alice, 'timeline:home')}"',
      ].join('\n');
      final yaml =
          '''
version: 1
accounts:
  - "$alice"
deck_columns:
$many
settings: {}
''';

      final target = await targetWith(
        [alice],
        deck: [column('mine', alice, 'timeline:home')],
      );
      final result = await apply(target, yaml);

      expect(target.getStringList(deckColumnsBackupKey), [
        column('mine', alice, 'timeline:home'),
      ]);
      expect(result.skipped[deckColumnsBackupKey], contains('多すぎます'));
    });

    test('⚠ id が重複した行は捨てる（並べ替え・削除の対象が決まらなくなる）', () async {
      final yaml =
          '''
version: 1
accounts:
  - "$alice"
deck_columns:
  - "${column('c1', alice, 'timeline:home')}"
  - "${column('c1', alice, 'timeline:local')}"
settings: {}
''';

      final target = await targetWith([alice]);
      final result = await apply(target, yaml);

      expect(target.getStringList(deckColumnsBackupKey), [
        column('c1', alice, 'timeline:home'),
      ]);
      expect(result.skipped[deckColumnsBackupKey], contains('1 件'));
    });

    test('deck_columns が map なら理由を残して何もしない', () async {
      final yaml =
          '''
version: 1
accounts:
  - "$alice"
deck_columns:
  こわれた: true
settings: {}
''';

      final target = await targetWith(
        [alice],
        deck: [column('mine', alice, 'timeline:home')],
      );
      final result = await apply(target, yaml);

      expect(target.getStringList(deckColumnsBackupKey), [
        column('mine', alice, 'timeline:home'),
      ]);
      expect(result.skipped[deckColumnsBackupKey], 'デッキの構成が読めませんでした');
    });

    test('deck_columns が無いファイル（旧版）も読める', () async {
      final yaml =
          '''
version: 1
accounts:
  - "$alice"
settings:
  font_scale: 1.2
''';

      final target = await targetWith([alice]);
      final result = await apply(target, yaml);

      expect(target.getDouble('font_scale'), 1.2);
      expect(target.getStringList(deckColumnsBackupKey), isNull);
      expect(result.skipped, isNot(contains(deckColumnsBackupKey)));
    });
  });

  test('⚠ 書き出したファイルを読み込むと元に戻る（ラウンドトリップ）', () async {
    final source = await prefsWith({
      'capsicum_account_keys_v2': '["$alice","$bob"]',
      deckColumnsBackupKey: [
        column('c1', alice, 'timeline:home'),
        column('c2', bob, 'channel:ak31f5utjv'),
        column('c3', alice, 'hashtag:precure_fun'),
      ],
    });
    final yaml = yamlOf(source);

    final target = await prefsWith(<String, Object>{});
    await apply(target, yaml);

    expect(target.getStringList(deckColumnsBackupKey), [
      column('c1', alice, 'timeline:home'),
      column('c2', bob, 'channel:ak31f5utjv'),
      column('c3', alice, 'hashtag:precure_fun'),
    ]);
  });
}

/// 残骸 secret が無い状態を与える（`purgeStaleSecrets` の fail-closed を避ける）。
class _NoSecretsStorage extends FlutterSecureStorage {
  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => false;
}
