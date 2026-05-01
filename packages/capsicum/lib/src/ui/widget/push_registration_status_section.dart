import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/push_registration_status_provider.dart';
import '../../service/push_registration_service.dart';
import '../../service/push_registration_status.dart';

/// 現アカウントのプッシュ通知登録状態を表示する共有 widget。
///
/// サーバー情報画面・プロフィール画面など複数の画面で同一の判定ロジック・
/// 文言・遷移先を提供する。設定 → プッシュ通知の per-account tile と挙動を
/// 揃え、失敗時は再試行・全アカウントの状態確認 (/settings/push) への動線を
/// 出す。
class PushRegistrationStatusSection extends ConsumerWidget {
  /// セクション見出し。`null` のときは見出しを描画しない。デフォルトは
  /// 「プッシュ通知」。サーバー情報画面・プロフィール画面で見出しの揃いを
  /// 取るため widget 内で完結させる（呼び出し側で別途 _SectionHeader を
  /// 置く必要はない）。
  final String? title;

  const PushRegistrationStatusSection({super.key, this.title = 'プッシュ通知'});

  static const _actionButtonWidth = 160.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    if (account == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('アカウント情報を取得できませんでした'),
      );
    }
    final accounts = ref.watch(accountManagerProvider).accounts;
    final hasPreset = PushRegistrationService.hasPresetAmong(accounts);
    final eligible =
        hasPreset || PushRegistrationService.isPresetServer(account.key.host);
    final statusMap =
        ref.watch(pushRegistrationStatusProvider).valueOrNull ??
        const <String, PushRegistrationSnapshot>{};
    final snapshot = statusMap[account.key.toStorageKey()];
    final state = snapshot?.state ?? PushRegistrationState.idle;
    final theme = Theme.of(context);

    final (statusText, statusColor, statusIcon) = _describe(
      theme,
      state,
      eligible,
      snapshot?.reason,
    );

    final retryable =
        eligible &&
        (state == PushRegistrationState.failed ||
            state == PushRegistrationState.idle ||
            state == PushRegistrationState.skipped);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              title!,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ListTile(
          leading: Icon(statusIcon, color: statusColor),
          title: Text(statusText),
          subtitle: snapshot?.errorMessage != null
              ? Text(snapshot!.errorMessage!)
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Wrap(
            spacing: 8,
            children: [
              if (retryable)
                SizedBox(
                  width: _actionButtonWidth,
                  child: TextButton.icon(
                    onPressed: () => PushRegistrationService.registerAccount(
                      account,
                      eligible: hasPreset,
                    ),
                    icon: const Icon(Icons.refresh),
                    label: const Text('再試行'),
                  ),
                ),
              SizedBox(
                width: _actionButtonWidth,
                child: TextButton.icon(
                  onPressed: () => context.push('/settings/push'),
                  icon: const Icon(Icons.tune),
                  label: const Text('全アカウント'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  (String, Color, IconData) _describe(
    ThemeData theme,
    PushRegistrationState state,
    bool eligible,
    PushRegistrationFailureReason? reason,
  ) {
    if (!eligible) {
      return (
        '登録対象外（プリセットサーバーのアカウント未登録）',
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
      PushRegistrationState.failed =>
        reason == PushRegistrationFailureReason.permissionDenied
            ? (
                '通知の権限が許可されていません',
                theme.colorScheme.error,
                Icons.notifications_off_outlined,
              )
            : ('登録に失敗しました', theme.colorScheme.error, Icons.error_outline),
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
}
