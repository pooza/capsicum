import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../model/account_key.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../service/settings_backup.dart';

/// 取り込んだバックアップを**実行中のアプリへ反映する** (#1001)。
///
/// ⚠ **呼び出し側が 2 つあるので、ここに寄せる**（Codex P2 / PR #1002）。設定画面
/// （ログイン後）とサーバー選択画面（ログイン前）の両方から取り込めるが、片方に
/// しか反映処理が無いと「読み込んだのに変わらない」が**その画面でだけ**起きる。
/// 実際 2 巡目のレビューで、ログイン前の経路が providers も account manager も
/// 触っていないことを指摘された。
///
/// やることは 2 つ:
///
/// 1. **設定の反映** … 各 Notifier は `build()` で prefs を読み直すので、
///    invalidate すれば画面が新しい設定で組み直される（再起動を求めない）。
///    ⚠ ログイン前でも要る — `themeModeProvider` / `fontScaleProvider` は
///    `main.dart` が既に読んでおり、放っておくとプロセスが終わるまで古い値のまま。
/// 2. **アカウントの反映** … 索引を書いただけでは画面に出ない。`restoreSessions`
///    は起動時に 1 度しか索引を読まないので、足したぶんを「未接続」として積む
///    （[AccountManagerNotifier.addDisconnectedAccounts]）。
void applyImportedSettingsBackup(WidgetRef ref, SettingsImportResult result) {
  for (final provider in backedUpPreferenceProviders) {
    ref.invalidate(provider);
  }

  if (result.addedAccountKeys.isEmpty) return;

  final keys = <AccountKey>[];
  for (final raw in result.addedAccountKeys) {
    try {
      keys.add(AccountKey.fromStorageKey(raw));
    } catch (_) {
      // 取り込み側が正規形へ直したうえで積んでいるので通常は来ない。保険。
      continue;
    }
  }
  ref.read(accountManagerProvider.notifier).addDisconnectedAccounts(keys);
}

/// 取り込みの前に必ず挟む確認 (#1010)。
///
/// ⚠ **ログイン前の経路でも要る。** `/server` は新しい端末だけの画面ではなく、
/// ドロワーの「アカウントを追加」と未接続アカウントの「接続し直す」からも開く。
/// つまり**設定を持っている端末**からも取り込みボタンを押せる。上書きを元に
/// 戻す手段は無いので、確認も反映（[applyImportedSettingsBackup]）と同じく
/// 両画面で共通にする。
Future<bool> confirmSettingsBackupImport(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('設定を読み込む'),
      content: const Text(
        'この端末の設定が、ファイルの内容で上書きされます。\n'
        'ファイルに入っているアカウントは一覧へ追加されます'
        '（この端末の既存のアカウントは消えません）。よろしいですか？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('読み込む'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// 取り込まなかったキーの内訳を Sentry へ残す (#968)。
///
/// 画面には件数しか出ず記録も残らないため、版をまたいで互換が崩れても（未知の
/// キー・型違い・範囲外が増えても）気付けなかった。**キー名と理由だけ**を載せ、
/// **値は載せない**（テンプレート履歴・フォント名などが入るため）。失敗ではなく
/// 分布観測なので captureMessage（info）で、fingerprint は 1 本に集約する。
///
/// ⚠ **こちらも両画面で共通** (#1010)。移行の主経路はログイン前なので、そこで
/// 観測が落ちていると分布がログイン後の再取り込みに偏る。
void reportSettingsBackupImportSkips(SettingsImportResult result) {
  if (result.skipped.isEmpty) return;
  try {
    Sentry.captureMessage(
      'settings_backup: import skipped ${result.skipped.length} keys',
      level: SentryLevel.info,
      withScope: (scope) {
        scope.setTag('settings_backup.op', 'import_skip');
        // key -> 理由。値は含めない（result.skipped は key→理由 の対応）。
        scope.setContexts('settings_backup_skipped', {
          for (final entry in result.skipped.entries) entry.key: entry.value,
        });
        scope.fingerprint = ['settings_backup.op', 'import_skip'];
      },
    );
  } catch (_) {
    // Sentry 失敗で UI を止めない。
  }
}

/// 取り込めなかった件数の但し書き。何も落ちていなければ空文字 (#1010)。
///
/// ⚠ **成功メッセージに必ず添える。** 索引の保存に失敗すると `skipped` にだけ
/// 記録されて `addedAccountKeys` は空になるので、これが無いと「設定を読み込み
/// ました」だけが出て**部分失敗が無言になる**。
String settingsBackupSkippedNote(SettingsImportResult result) =>
    result.skipped.isEmpty ? '' : '（${result.skipped.length} 件は取り込みませんでした）';
