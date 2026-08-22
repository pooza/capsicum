import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #1010: バックアップの取り込み口が 2 つあることの検査。
///
/// 設定画面（ログイン後）とサーバー選択画面（ログイン前）の両方から取り込める。
/// **反映処理だけを共通化して、その手前を割ったまま**にしていたため、ログイン前
/// の経路には確認ダイアログも失敗の計装も無かった。`/server` は新しい端末専用の
/// 画面ではなく、ドロワーの「アカウントを追加」と未接続アカウントの「接続し直す」
/// からも開くので、**設定を持っている端末の設定が無確認で上書きされる**。
///
/// ソースを読む検査なのは、ログイン前の画面がファイル選択（OS のピッカー）から
/// 始まるため。widget test では `openFile` の先へ進めず、確認ダイアログの有無を
/// 押さえられない。
void main() {
  const entries = {
    'ログイン後（設定画面）': 'lib/src/ui/screen/settings/settings_backup_screen.dart',
    'ログイン前（サーバー選択画面）': 'lib/src/ui/screen/server_selection_screen.dart',
  };

  for (final entry in entries.entries) {
    group(entry.key, () {
      final source = File(entry.value).readAsStringSync();

      test('取り込みの前に確認を挟む', () {
        expect(
          source,
          contains('confirmSettingsBackupImport('),
          reason:
              '${entry.value} が確認を挟んでいない。上書きは元に戻せないので、'
              '両方の入口で共通の確認を通すこと (#1010)',
        );
      });

      test('取り込めなかったキーを Sentry へ残す', () {
        expect(
          source,
          contains('reportSettingsBackupImportSkips('),
          reason:
              '${entry.value} が skip を観測していない。移行の主経路はログイン前'
              'なので、片方だけだと分布が偏る (#968 / #1010)',
        );
      });

      test('取り込みの失敗を観測する', () {
        expect(
          source,
          contains('reportOpFailure('),
          reason:
              '${entry.value} が失敗を計装していない。新規のファイル I/O は'
              '失敗率を見る約束になっている (#968)',
        );
      });

      test('部分失敗の但し書きを画面に出す', () {
        expect(
          source,
          contains('settingsBackupSkippedNote('),
          reason:
              '${entry.value} が但し書きを出していない。索引の保存に失敗すると'
              '追加 0 件になるので、これが無いと部分失敗が無言になる (#1010)',
        );
      });
    });
  }
}
