import 'package:flutter_riverpod/flutter_riverpod.dart';

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
