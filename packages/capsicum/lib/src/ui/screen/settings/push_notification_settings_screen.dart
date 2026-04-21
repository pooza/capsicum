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
/// 非表示化の基準:
/// - プリセットサーバー以外のアカウントは「登録対象外」として小さく表示
/// - [PushRegistrationState.notSupported]（Misskey upstream 制約など）は
///   サーバー側の仕様制約として明示。リトライ不可
class PushNotificationSettingsScreen extends ConsumerWidget {
  const PushNotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountManagerProvider).accounts;
    final statusMap =
        ref.watch(pushRegistrationStatusProvider).valueOrNull ??
        const <String, PushRegistrationSnapshot>{};

    return Scaffold(
      appBar: AppBar(
        title: const Text('プッシュ通知'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'プッシュ通知はプリセットサーバーのアカウントで利用できます。'
              '登録に失敗した場合は、各アカウントの行から再試行できます。',
              style: TextStyle(fontSize: 13),
            ),
          ),
          ...accounts.map(
            (account) => _AccountStatusTile(
              account: account,
              snapshot: statusMap[account.key.toStorageKey()],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountStatusTile extends ConsumerWidget {
  const _AccountStatusTile({required this.account, required this.snapshot});

  final Account account;
  final PushRegistrationSnapshot? snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPreset = kPresetServerHosts.contains(account.key.host);
    final label = '@${account.key.username}@${account.key.host}';
    final state = snapshot?.state ?? PushRegistrationState.idle;

    final (statusText, statusColor, statusIcon) = _describeState(
      context,
      state,
      isPreset,
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
      trailing: _isRetryable(state, isPreset)
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
    bool isPreset,
  ) {
    final theme = Theme.of(context);
    if (!isPreset) {
      return (
        '登録対象外（プリセットサーバー以外）',
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

  bool _isRetryable(PushRegistrationState state, bool isPreset) {
    if (!isPreset) return false;
    return state == PushRegistrationState.failed ||
        state == PushRegistrationState.idle;
  }

  void _retry(WidgetRef ref, Account account) {
    final accounts = ref.read(accountManagerProvider).accounts;
    final hasPreset = accounts.any(
      (a) => kPresetServerHosts.contains(a.key.host),
    );
    PushRegistrationService.registerAccount(account, eligible: hasPreset);
  }
}
