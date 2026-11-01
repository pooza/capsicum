import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/deck_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../service/post_account_idle_tracker.dart';
import '../widget/server_badge.dart';

/// 投稿先を確かめる条件 (#1306)。
bool shouldConfirmPostAccount({
  required bool enabled,
  required bool deckOpen,
  required int accountCount,
  required bool resumed,
}) => enabled && deckOpen && accountCount >= 2 && resumed;

/// 間が空いて再開したあとの最初の投稿で、投稿先を確かめる (#1306)。
///
/// 戻り値が false なら送らない。入力は残る。
///
/// ⚠⚠ **書く前には尋ねない。**再開は何かを思いついて投稿する場面で、勢いを止めると
/// ストレスが大きい（2026-10-21 pooza）。送るときの 1 回だけにする。
Future<bool> confirmPostAccountIfNeeded(
  BuildContext context,
  WidgetRef ref, {
  PostAccountIdleTracker? tracker,
}) async {
  final idle = tracker ?? postAccountIdleTracker;
  final account = ref.read(currentAccountProvider);
  if (account == null ||
      !shouldConfirmPostAccount(
        enabled: ref.read(confirmPostAccountAfterIdleProvider),
        deckOpen: ref.read(mountedDeckCountProvider) > 0,
        accountCount: ref.read(accountManagerProvider).accounts.length,
        resumed: idle.pending,
      )) {
    return true;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('投稿先の確認'),
      content: Text(
        '${serverDisplayName(account.key.host)} に投稿します。\n'
        '@${account.key.username}@${account.key.host}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('投稿'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  idle.clear();
  return true;
}
