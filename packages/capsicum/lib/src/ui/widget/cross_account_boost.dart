import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../util/post_action_error.dart';
import 'emoji_text.dart';
import 'server_badge.dart';
import 'user_avatar.dart';

/// アクティブなアカウント以外に、ログイン済みアカウントが存在するか。
///
/// 「別アカウントでブースト / リノート」メニューの表示判定に使う。
bool hasOtherAccounts(WidgetRef ref) {
  final state = ref.read(accountManagerProvider);
  final currentKey = state.current?.key;
  return state.accounts.any((a) => a.key != currentKey);
}

/// 表示中の投稿を、今アクティブなアカウント以外のログイン済みアカウントで
/// ブースト（Mastodon）/ リノート（Misskey）する導線（#744）。
///
/// 別垢 B の鯖は元投稿を知らないことがあるため、投稿 URL を B の鯖で
/// resolve-by-URL（Mastodon: `/api/v2/search?resolve=true` / Misskey:
/// `ap/show`）して B 側の id を得てから [repeatPost] する。解決できない
/// 場合は SnackBar で明示する。
Future<void> showCrossAccountBoostPicker({
  required BuildContext context,
  required WidgetRef ref,
  required Post targetPost,
}) async {
  final state = ref.read(accountManagerProvider);
  final currentKey = state.current?.key;
  final others = state.accounts.where((a) => a.key != currentKey).toList();
  if (others.isEmpty) return;

  // メニュー外側の context が後で deactivate されても使えるよう退避。
  final messenger = ScaffoldMessenger.of(context);
  final themeColors = ref.read(hostThemeColorProvider);

  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('別アカウントで実行'),
              ),
            ),
            ...others.map(
              (account) => ListTile(
                leading: UserAvatar(
                  user: account.user,
                  size: 32,
                  compact: true,
                ),
                title: EmojiText(
                  account.user.displayName ?? account.user.username,
                  emojis: account.user.emojis,
                  fallbackHost: account.user.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '@${account.user.username}@${account.key.host}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: ServerBadge.fromHost(
                        account.key.host,
                        themeColors: themeColors,
                      ),
                    ),
                  ],
                ),
                trailing: Text(_boostLabel(account)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _boostWithAccount(messenger, account, targetPost);
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// アカウント [account] の文脈でのブースト / リノートの呼称。
String _boostLabel(Account account) =>
    account.mulukhiya?.reblogLabel ??
    (account.adapter is ReactionSupport ? 'リノート' : 'ブースト');

Future<void> _boostWithAccount(
  ScaffoldMessengerState messenger,
  Account account,
  Post targetPost,
) async {
  final label = _boostLabel(account);
  final name = account.user.displayName ?? account.user.username;
  final url = targetPost.url;
  final adapter = account.adapter;

  if (url == null || adapter is! SearchSupport) {
    messenger.showSnackBar(SnackBar(content: Text('この投稿は$nameでは$labelできません')));
    return;
  }

  // 解決の往復が入るため進捗を出す。終了時のメッセージが後ろで待たないよう、
  // 結果表示の直前にこの「解決中…」を消す。
  messenger.showSnackBar(SnackBar(content: Text('$nameで解決中…')));
  try {
    // 別垢 B の鯖で元投稿 URL を解決し、B から見た id を得る。
    final results = await (adapter as SearchSupport).search(url);
    if (results.posts.isEmpty) {
      messenger.removeCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('$nameの鯖で投稿を解決できませんでした')));
      return;
    }
    await adapter.repeatPost(results.posts.first.id);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('$nameで$labelしました')));
  } catch (e) {
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(describePostActionError(e))));
  }
}
