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
    //
    // ⚠⚠ **上限ちょうどのファイルで測ること (#1027-E)。**以前はここが 24 バイトの
    // ファイルで、**境界を一度も踏んでいなかった**。実装の `>` を `>=` に変えても
    // 緑のまま通る＝「ちょうど」を名乗りながら何も見ていない検査だった。
    test('上限ちょうどは通す', () async {
      final file = File('${dir.path}/ok.yaml')
        ..writeAsBytesSync(List.filled(maxSettingsBackupBytes, 0x41));

      expect(
        await readSettingsBackupFile(XFile(file.path)),
        hasLength(maxSettingsBackupBytes),
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

    /// #1025: 捕まえるのが遅すぎた。⚠ **例外に「する」だけでは足りない** —
    /// `StackOverflowError` に到達するまでメイン isolate が同期的に回り続け、
    /// 実測で最大 65 秒無反応になっていた（Android は ANR、iOS はウォッチドッグ
    /// の射程）。**弾くのが速いこと**まで含めて固定する。
    ///
    /// ⚠ 時間で測る検査なので閾値は緩く取る。CI の遅いマシンでも、パースまで
    /// 落ちていれば桁が違う（同じ深さで 65 秒）ので取り違えようがない。
    test('深いファイルはパースへ入る前に、即座に弾く', () async {
      final prefs = await emptyPrefs();
      const depth = 200000;
      final bomb = '${'[' * depth}${']' * depth}';

      final sw = Stopwatch()..start();
      await expectLater(
        applySettingsBackupYaml(prefs, 'version: 1\nsettings: $bomb\n'),
        throwsA(isA<SettingsBackupFormatException>()),
      );
      sw.stop();

      expect(
        sw.elapsedMilliseconds,
        lessThan(2000),
        reason:
            'パースへ入っている。深さ 200,000 は実測 65 秒で、その間 UI は'
            '固まったままになる (#1025)',
      );
    });

    group('入れ子の深さの門番 (#1025)', () {
      String flow(int depth) => '${'[' * depth}${']' * depth}';

      // ⚠ **自分が書き出したファイルを自分で弾かないこと。**門番を足すときに
      // 一番やりやすい壊し方なので、実物の書き出しを通して往復で確かめる。
      test('自分が書き出したファイルは通す', () async {
        final prefs = await emptyPrefs();
        final exported = buildSettingsBackupYaml(
          prefs,
          appVersion: '1.61.0+174',
          exportedAt: '2026-08-27T00:00:00Z',
        );

        expect(exceedsSettingsBackupNestingDepth(exported), isFalse);
      });

      test('手編集で多少入れ子になっていても通す', () {
        expect(
          exceedsSettingsBackupNestingDepth(
            'version: 1\nsettings:\n  a: [1, 2, [3]]\naccounts:\n  - x\n',
          ),
          isFalse,
        );
      });

      test('上限ちょうどは通し、1 段超えたら弾く', () {
        expect(
          exceedsSettingsBackupNestingDepth(
            flow(maxSettingsBackupNestingDepth),
          ),
          isFalse,
        );
        expect(
          exceedsSettingsBackupNestingDepth(
            flow(maxSettingsBackupNestingDepth + 1),
          ),
          isTrue,
        );
      });

      test('閉じたぶんは戻る（横に並べても深さにならない）', () {
        // `[] [] [] ...` を上限より多く並べても、同時に開いているのは 1 段。
        final wide = List.filled(
          maxSettingsBackupNestingDepth * 4,
          '[]',
        ).join();
        expect(exceedsSettingsBackupNestingDepth(wide), isFalse);
      });

      // ⚠ ここを飛ばさないと、本文に `[` を含む設定値（投稿テンプレート等）が
      // 深さに数えられ、**正しいファイルを誤って弾く**。
      test('引用符の中の括弧は数えない', () {
        final inside = '[' * (maxSettingsBackupNestingDepth + 10);
        expect(
          exceedsSettingsBackupNestingDepth(
            'version: 1\nsettings:\n  a: "$inside"\n',
          ),
          isFalse,
        );
        expect(
          exceedsSettingsBackupNestingDepth(
            "version: 1\nsettings:\n  a: '$inside'\n",
          ),
          isFalse,
        );
      });

      test('二重引用符の中のエスケープを読み飛ばす', () {
        final inside = '[' * (maxSettingsBackupNestingDepth + 10);
        expect(
          exceedsSettingsBackupNestingDepth(
            r'a: "\" '
            '$inside'
            r'"',
          ),
          isFalse,
          reason: r'\" を閉じ引用符と誤読すると、以降の括弧を数えてしまう',
        );
      });

      test("単一引用符の '' エスケープを読み飛ばす", () {
        final inside = '[' * (maxSettingsBackupNestingDepth + 10);
        expect(
          exceedsSettingsBackupNestingDepth("a: 'it''s $inside'"),
          isFalse,
        );
      });

      test('コメントの中の括弧は数えない', () {
        final inside = '[' * (maxSettingsBackupNestingDepth + 10);
        expect(
          exceedsSettingsBackupNestingDepth('# $inside\nversion: 1\n'),
          isFalse,
        );
      });

      group('⚠⚠ 引用符 1 個でガードが無効化される (#1035-A1)', () {
        // ⚠ **上のテスト群は素直なペイロードしか見ていなかった。**引用符は
        // 「スカラー全体を囲む」形しか試しておらず、**平文スカラーの途中に
        // 引用符が 1 個だけ現れる形**が抜けていた。
        //
        // 実測（yaml 3.1.3）: `bait: x"` + 250,000 段のネストで、ガードは
        // **false（素通り）**、`loadYaml` が **100,690ms 同期的にメイン isolate
        // を占有**したのち StackOverflowError。#1025 が挙げた ANR /
        // ウォッチドッグの状況がそのまま再現する。

        test('平文スカラーの途中の " は引用開始ではない（以降も数える）', () {
          // ⚠ `bait: x"` は**正当な YAML**。ここで引用が始まったと誤読すると、
          // 閉じが無いのでファイル末尾まで飛び、以降の `[` を 1 つも数えない。
          final deep = '[' * (maxSettingsBackupNestingDepth + 10);
          expect(
            exceedsSettingsBackupNestingDepth('bait: x"\na: $deep\n'),
            isTrue,
            reason: '起票時の再現ペイロードそのもの',
          );
        });

        test("平文スカラーの途中の ' も同じ（a: don't）", () {
          final deep = '[' * (maxSettingsBackupNestingDepth + 10);
          expect(
            exceedsSettingsBackupNestingDepth("a: don't\nb: $deep\n"),
            isTrue,
          );
        });

        test('平文スカラーの途中の # はコメント開始ではない', () {
          // YAML のコメントは行頭か空白の後ろだけ。`tag#1` の `#` は本文。
          final deep = '[' * (maxSettingsBackupNestingDepth + 10);
          expect(exceedsSettingsBackupNestingDepth('a: tag#1 $deep\n'), isTrue);
        });

        test('閉じない引用符は弾く側へ倒す', () {
          // ⚠ 閉じない引用符を持つファイルは `loadYaml` でもどうせ失敗する。
          // **数十秒かけて失敗するより先に弾く**ほうがよい。
          expect(
            exceedsSettingsBackupNestingDepth('a: "abc\n'),
            isTrue,
            reason: '閉じ引用符が無いまま EOF。素通りさせると後段が刺さる',
          );
          expect(exceedsSettingsBackupNestingDepth("a: 'abc\n"), isTrue);
        });

        test('⚠ 正しく閉じた引用符は従来どおり通す（過剰に弾かない）', () {
          // 弾く側へ倒したことで、**正しいファイルまで弾いていないか**を押さえる。
          final deep = '[' * (maxSettingsBackupNestingDepth + 10);
          expect(
            exceedsSettingsBackupNestingDepth('a: "$deep"\nb: 1\n'),
            isFalse,
          );
          expect(
            exceedsSettingsBackupNestingDepth('a: "x\\"y"\nb: 1\n'),
            isFalse,
          );
        });
      });
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
