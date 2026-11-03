import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/deck_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../service/post_account_idle_tracker.dart';
import 'link_target_account.dart';

/// 投稿先を確かめる条件 (#1306)。
bool shouldConfirmPostAccount({
  required bool enabled,
  required bool deckOpen,
  required int accountCount,
  required bool resumed,
}) => enabled && deckOpen && accountCount >= 2 && resumed;

/// [confirmPostAccountIfNeeded] の結果。
enum PostAccountConfirmResult {
  /// 尋ねなかった。「投稿前に確認する」はこのときだけ出す。
  notAsked,

  /// 尋ねて、投稿を選んだ。
  confirmed,

  /// 尋ねて、取り消した。送らない。
  cancelled,
}

/// 間が空いて再開したあとの最初の投稿で、投稿先を確かめる (#1306)。
///
/// [PostAccountConfirmResult.cancelled] なら送らない。入力は残る。
///
/// ⚠ 尋ねて投稿を選んだ（[PostAccountConfirmResult.confirmed]）ときは、
/// 「投稿前に確認する」を重ねない。同じ投稿に 2 回尋ねることになる。
///
/// ⚠⚠ **書く前には尋ねない。**再開は何かを思いついて投稿する場面で、勢いを止めると
/// ストレスが大きい（2026-10-21 pooza）。送るときの 1 回だけにする。
Future<PostAccountConfirmResult> confirmPostAccountIfNeeded(
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
    return PostAccountConfirmResult.notAsked;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('投稿先の確認'),
      // ⚠ 手で組み立てない。サーバーの名前を引く前はホスト名が返るので、
      // 「host に投稿します。@user@host」とホスト名が 2 回出ていた。
      content: Text('${linkTargetAccountLabel(account.key)} に投稿します。'),
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
  if (confirmed != true) return PostAccountConfirmResult.cancelled;
  idle.clear();
  return PostAccountConfirmResult.confirmed;
}
