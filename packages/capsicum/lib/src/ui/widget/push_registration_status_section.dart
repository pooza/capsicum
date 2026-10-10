import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/entitlement_status_provider.dart';
import '../../provider/push_registration_status_provider.dart';
import '../../service/push_registration_service.dart';
import '../../service/push_registration_status.dart';
import 'section_header.dart';

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
      // ⚠ **買えば使えることが分かる文面にする (#1218)。**以前は
      // 「プリセットサーバーのアカウントが未登録」だけで、**利用権という
      // もう 1 本の経路が存在しないように読めた**。
      '登録対象外（プリセットサーバーのアカウントか、プッシュ通知リレーの利用権が必要）',
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
    PushRegistrationState.failed => switch (reason) {
      PushRegistrationFailureReason.permissionDenied => (
        '通知の権限が許可されていません',
        theme.colorScheme.error,
        Icons.notifications_off_outlined,
      ),
      // ⚠ **利用権の節と同じことを言う (#1237)。**手元に記録はあるのに relay が
      // 認めなかった回。「登録に失敗しました」だけだと、節の説明と行が別々の
      // ことを言っているように見える。次の一手（復元）も節にある。
      PushRegistrationFailureReason.entitlementRejected => (
        'プッシュ通知リレーの利用権を確認できませんでした',
        theme.colorScheme.error,
        Icons.error_outline,
      ),
      _ => ('登録に失敗しました', theme.colorScheme.error, Icons.error_outline),
    },
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

/// 「再試行」を出すか (#1237)。登録対象で、まだ登録できていない状態のとき。
///
/// ⚠ 設定 → プッシュ通知の行と、サーバー情報の節に同じ式が写されていた。
bool isPushRegistrationRetryable(
  PushRegistrationState state, {
  required bool eligible,
}) =>
    eligible &&
    (state == PushRegistrationState.failed ||
        state == PushRegistrationState.idle ||
        state == PushRegistrationState.skipped);

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
    // プッシュ通知の経路が無いプラットフォーム（現状は Linux だけ・#475）では
    // UI ごと隠す。表示しても登録は必ず token 取得失敗となり、ユーザーが再試行を
    // 繰り返す混乱状態になるため。macOS (#468) と Windows (#474) は配線済み。
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
    // 🔴 接続できていないプリセットのアカウントも数える
    // （[hasPresetAccountProvider]）。
    final hasPreset = ref.watch(hasPresetAccountProvider);
    // ⚠⚠ **`watch` より先に `hasPreset` で抜ける**（#1123 の完了条件 3）。
    // プリセットのみの人に利用権の問い合わせを走らせない。
    final hasEntitlement =
        !hasPreset &&
        attemptsRegistrationWith(ref.watch(entitlementStatusProvider).view);
    // ⚠⚠ **判定はサービス側の 1 本を呼ぶ (#1218)。**書き写すと経路が増えた
    // ときに取り残される（買った人に「登録対象外」と出していた）。
    final eligible = PushRegistrationService.shouldAttemptRegistration(
      host: account.key.host,
      eligible: hasPreset,
      hasEntitlement: hasEntitlement,
    );
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

    final retryable = isPushRegistrationRetryable(state, eligible: eligible);

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
