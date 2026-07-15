import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'section_header.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/push_registration_status_provider.dart';
import '../../service/push_registration_service.dart';
import '../../service/push_registration_status.dart';

/// プッシュ通知登録状態の表示文言・色・アイコンを返す共通ロジック。
/// 設定 → プッシュ通知画面とサーバー情報 / プロフィールの
/// [PushRegistrationStatusSection] が同一の判定を使うために抽出してある。
(String, Color, IconData) describePushRegistrationStatus(
  ThemeData theme,
  PushRegistrationState state,
  bool eligible,
  PushRegistrationFailureReason? reason,
) {
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
      // theme.colorScheme に「成功」枠の色が無いため Material のシェード値で
      // 代替。shade400 はライト/ダーク両モードで十分なコントラストを確保
      // できる中間調。
      Colors.green.shade400,
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

/// 現アカウントのプッシュ通知登録状態を表示する共有 widget。
///
/// 現状の使用箇所はサーバー情報画面のみ。設定 → プッシュ通知の per-account
/// tile と判定ロジック・文言を揃え、失敗時は「再試行」への動線を出す。全
/// アカウント横断設定 (/settings/push) への動線はサーバー情報のスコープ外
/// なので置かない（#817）。
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
    // 本配線が無いプラットフォームでは UI ごと隠す
    // （#467: macOS / #471: Linux / #423: Windows）。表示しても登録は必ず
    // token 取得失敗となり、ユーザーが再試行を繰り返す混乱状態になるため、
    // 本配線が入るまでの暫定対応。
    if (!PushRegistrationService.isPushBackendWired) {
      return const SizedBox.shrink();
    }
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

    final (
      statusText,
      statusColor,
      statusIcon,
    ) = describePushRegistrationStatus(
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
        if (title != null) SectionHeader(title!),
        ListTile(
          leading: Icon(statusIcon, color: statusColor),
          title: Text(statusText),
          subtitle: snapshot?.errorMessage != null
              ? Text(snapshot!.errorMessage!)
              : null,
        ),
        // 「全アカウント」(/settings/push) への動線はサーバー情報のスコープ外
        // なので置かない（設定 → プッシュ通知から到達可能）。このサーバーでの
        // 自分のプッシュ状態の「再試行」だけ残す（#817）。
        if (retryable)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SizedBox(
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
          ),
      ],
    );
  }
}
