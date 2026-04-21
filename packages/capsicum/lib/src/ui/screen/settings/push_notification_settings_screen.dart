import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../model/account.dart';
import '../../../preset_servers.dart';
import '../../../provider/account_manager_provider.dart';
import '../../../provider/push_registration_status_provider.dart';
import '../../../service/push_registration_service.dart';
import '../../../service/push_registration_status.dart';

/// プッシュ通知の登録状態をアカウント別に一覧表示し、失敗していれば
/// 再試行できる設定画面（#340）。
///
/// 「eligible」の解釈は [PushRegistrationService.registerAllAccounts] と
/// 揃える — プリセットサーバーのアカウントが 1 つでもあれば、非プリセット
/// アカウントも登録対象になる。UI 側もこの eligibility に従って表示・
/// リトライ可否を出し分ける。
class PushNotificationSettingsScreen extends ConsumerWidget {
  const PushNotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountManagerProvider).accounts;
    final statusMap =
        ref.watch(pushRegistrationStatusProvider).valueOrNull ??
        const <String, PushRegistrationSnapshot>{};
    final hasPreset = accounts.any(
      (a) => kPresetServerHosts.contains(a.key.host),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('プッシュ通知'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              hasPreset
                  ? 'プリセットサーバーのアカウントが登録されているため、'
                        'すべてのアカウントでプッシュ通知が利用できます。'
                        '登録に失敗した場合は、各アカウントの行から再試行できます。'
                  : 'プッシュ通知はプリセットサーバーのアカウントが '
                        '1 つ以上登録されている場合に利用できます。',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          ...accounts.map(
            (account) => _AccountStatusTile(
              account: account,
              snapshot: statusMap[account.key.toStorageKey()],
              hasPreset: hasPreset,
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountStatusTile extends ConsumerWidget {
  const _AccountStatusTile({
    required this.account,
    required this.snapshot,
    required this.hasPreset,
  });

  final Account account;
  final PushRegistrationSnapshot? snapshot;
  final bool hasPreset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = '@${account.key.username}@${account.key.host}';
    final state = snapshot?.state ?? PushRegistrationState.idle;
    // プリセットサーバー本体か、プリセットがあって「連れて登録」される側か
    final eligible = hasPreset || kPresetServerHosts.contains(account.key.host);

    final (statusText, statusColor, statusIcon) = _describeState(
      context,
      state,
      eligible,
    );

    return ListTile(
      leading: Icon(statusIcon, color: statusColor),
      title: Text(label),
      subtitle: Text(
        [
          statusText,
          if (snapshot?.errorMessage != null) snapshot!.errorMessage!,
        ].join('\n'),
      ),
      isThreeLine: snapshot?.errorMessage != null,
      trailing: _isRetryable(state, eligible)
          ? TextButton(
              onPressed: () => _retry(ref, account),
              child: const Text('再試行'),
            )
          : null,
    );
  }

  (String, Color, IconData) _describeState(
    BuildContext context,
    PushRegistrationState state,
    bool eligible,
  ) {
    final theme = Theme.of(context);
    if (!eligible) {
      return (
        '登録対象外（プリセットサーバーのアカウントが未登録）',
        theme.colorScheme.outline,
        Icons.remove_circle_outline,
      );
    }
    return switch (state) {
      PushRegistrationState.idle => (
        '未登録',
        theme.colorScheme.outline,
        Icons.hourglass_empty,
      ),
      PushRegistrationState.registering => (
        '登録中…',
        theme.colorScheme.primary,
        Icons.sync,
      ),
      PushRegistrationState.registered => (
        '登録済み',
        Colors.green,
        Icons.check_circle,
      ),
      PushRegistrationState.failed => (
        '登録に失敗しました',
        theme.colorScheme.error,
        Icons.error_outline,
      ),
      PushRegistrationState.notSupported => (
        'このサーバーでは対応していません',
        theme.colorScheme.outline,
        Icons.block,
      ),
      PushRegistrationState.skipped => (
        '登録対象外',
        theme.colorScheme.outline,
        Icons.remove_circle_outline,
      ),
    };
  }

  bool _isRetryable(PushRegistrationState state, bool eligible) {
    if (!eligible) return false;
    return state == PushRegistrationState.failed ||
        state == PushRegistrationState.idle ||
        state == PushRegistrationState.skipped;
  }

  void _retry(WidgetRef ref, Account account) {
    final accounts = ref.read(accountManagerProvider).accounts;
    final hasPreset = accounts.any(
      (a) => kPresetServerHosts.contains(a.key.host),
    );
    PushRegistrationService.registerAccount(account, eligible: hasPreset);
  }
}
