import 'package:cross_file/cross_file.dart';
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

/// 選ばれたファイルを、上限を確かめてから読む (#1012)。
///
/// ⚠ **`readAsString` を直に呼ばない。**取り込み口は「YAML を選ぶ」導線だが、
/// iOS の UTI は `public.data` なので**任意のファイルを選べる**（Android も
/// mimeTypes の絞り込みは提供側次第）。動画を選ばれると、内容を見る前に
/// 端末のメモリへ丸ごと載る。
///
/// ⚠ **両方の取り込み口から呼ぶこと。**設定画面（ログイン後）とサーバー選択画面
/// （ログイン前）があり、片方だけ守ると守られていない側が残る（#996 が繰り返し
/// 踏んだ「母数の取りこぼし」）。
///
/// 大きすぎるファイルは [SettingsBackupFormatException] にする。ユーザーの選択
/// ミスであって障害ではないので、呼び出し側の format 用 catch（件数だけ数える）
/// へ落として error レベルの観測にしない。
Future<String> readSettingsBackupFile(XFile file) async {
  final length = await file.length();
  if (length > maxSettingsBackupBytes) {
    throw const SettingsBackupFormatException(
      '設定のバックアップにしてはファイルが大きすぎます。選んだファイルを確認してください',
    );
  }
  return file.readAsString();
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
        scope.setContexts(
          'settings_backup_skipped',
          redactSkippedKeysForReport(result.skipped),
        );
        scope.fingerprint = ['settings_backup.op', 'import_skip'];
      },
    );
  } catch (_) {
    // Sentry 失敗で UI を止めない。
  }
}

/// Sentry へ載せてよい形に落とす (#1012)。
///
/// ⚠ **「値は載せない」だけでは足りなかった。**未知のキーは YAML の
/// マッピングキーそのもの（＝ファイル由来の任意文字列）で、手編集された
/// バックアップならユーザーが書いた何でも入りうる。doc は「値は含めない」と
/// 宣言していたのに、**キー名の側から素通し**していた。
///
/// 知っているキー（[exportableSettings] / [deviceLocalKeys] /
/// [accountScopedKeys] と `accounts`）はそのまま出す — 素性が分かっている
/// 定数で、どの設定が落ちたかを知るのがこの観測の目的。それ以外は
/// `(unknown)` に丸めて**件数だけ**残す。
///
/// ⚠ **件数にも上限を置く。**壊れたファイルは未知キーを大量に持ちうるので、
/// context が肥大して Sentry 側で切り捨てられると全部見えなくなる。
@visibleForTesting
Map<String, Object> redactSkippedKeysForReport(Map<String, String> skipped) {
  const maxReported = 30;
  final known = <String, String>{};
  var unknown = 0;
  for (final entry in skipped.entries) {
    if (!_knownBackupKeys.contains(entry.key)) {
      unknown++;
      continue;
    }
    if (known.length >= maxReported) continue;
    known[entry.key] = entry.value;
  }
  return {
    ...known,
    if (unknown > 0) '(unknown)': unknown,
    if (skipped.length > known.length + unknown)
      '(truncated)': skipped.length - known.length - unknown,
  };
}

/// 素性の分かっているキー。ここに無いものは名前ごと伏せる。
final Set<String> _knownBackupKeys = {
  for (final setting in exportableSettings) setting.key,
  ...deviceLocalKeys,
  ...accountScopedKeys,
  // アカウント索引の取り込み結果 (#1001)。理由は定数文字列。
  'accounts',
};

/// 取り込めなかった件数の但し書き。何も落ちていなければ空文字 (#1010)。
///
/// ⚠ **成功メッセージに必ず添える。** 索引の保存に失敗すると `skipped` にだけ
/// 記録されて `addedAccountKeys` は空になるので、これが無いと「設定を読み込み
/// ました」だけが出て**部分失敗が無言になる**。
///
/// ⚠⚠ **アカウントだけは理由の本文を出す（v1.60 リリース前レビュー）。**
/// `_mergeAccounts` は「取り込めなかったことは理由つきで返し、ユーザーには
/// 『ログインし直す』という手が残る」と宣言して理由を組み立てているのに、
/// **どちらの画面もその値を読んでいなかった**。#621 の非 op delete を踏んだ
/// 端末では移行の主経路（ログイン前の取り込み）でアカウントが 1 件も入らず、
/// それでも画面には「1 件は取り込みませんでした」としか出ない。
///
/// 出すのは `accounts` の理由のみ。設定キー側は「端末固有だから飛ばした」等の
/// 正常系が大半で、全部並べると本当に困る 1 行が埋もれる。理由の文字列は
/// いずれも定数＋件数で、ファイル由来の値は入らない。
String settingsBackupSkippedNote(SettingsImportResult result) {
  if (result.skipped.isEmpty) return '';
  final accounts = result.skipped['accounts'];
  final others = result.skipped.length - (accounts == null ? 0 : 1);
  if (accounts == null) return '（$others 件は取り込みませんでした）';
  final tail = others > 0 ? '。ほか $others 件も取り込みませんでした' : '';
  return '（$accounts$tail）';
}
