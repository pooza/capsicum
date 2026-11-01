import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../util/op_error.dart';

enum _ChannelAction { follow, favorite, mute, edit }

/// チャンネルの操作のシート (#1051)。管理画面の行とタイムラインの画面から開く。
///
/// ⚠ 楽観的に表示を変えない。送って成功してから取り直すので、失敗しても戻す
/// ものが無い（`docs/product-policy.md`「閲覧のみの族の型」）。
Future<void> showChannelActions(
  BuildContext context,
  WidgetRef ref,
  Channel channel,
) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! ChannelManagementSupport) return;
  final support = adapter as ChannelManagementSupport;
  final account = ref.read(currentAccountProvider);
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final isOwner = channel.userId != null && channel.userId == account?.user.id;

  final action = await showModalBottomSheet<_ChannelAction>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              channel.isFollowing ? Icons.remove_circle_outline : Icons.add,
            ),
            title: Text(channel.isFollowing ? 'フォロー解除' : 'フォロー'),
            onTap: () => Navigator.pop(sheetContext, _ChannelAction.follow),
          ),
          ListTile(
            leading: Icon(channel.isFavorited ? Icons.star : Icons.star_border),
            title: Text(channel.isFavorited ? 'お気に入りから外す' : 'お気に入りに追加'),
            onTap: () => Navigator.pop(sheetContext, _ChannelAction.favorite),
          ),
          ListTile(
            leading: Icon(
              channel.isMuting ? Icons.volume_up : Icons.volume_off,
            ),
            title: Text(channel.isMuting ? 'ミュート解除' : 'ミュート'),
            onTap: () => Navigator.pop(sheetContext, _ChannelAction.mute),
          ),
          if (isOwner)
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('編集'),
              onTap: () => Navigator.pop(sheetContext, _ChannelAction.edit),
            ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;

  if (action == _ChannelAction.edit) {
    final saved = await context.push<bool>('/channels/edit', extra: channel);
    // ⚠ 編集の間に行が破棄されていることがあるので、下の操作と同じくコンテナへ当てる。
    if (saved == true) invalidateChannelsIn(container);
    return;
  }

  final id = channel.id;
  final (operation, run, done, failed) = switch (action) {
    _ChannelAction.follow =>
      channel.isFollowing
          ? (
              'unfollow',
              () => support.unfollowChannel(id),
              'フォローを解除しました',
              'フォロー解除に失敗しました',
            )
          : (
              'follow',
              () => support.followChannel(id),
              'フォローしました',
              'フォローに失敗しました',
            ),
    _ChannelAction.favorite =>
      channel.isFavorited
          ? (
              'unfavorite',
              () => support.unfavoriteChannel(id),
              'お気に入りから外しました',
              'お気に入りから外せませんでした',
            )
          : (
              'favorite',
              () => support.favoriteChannel(id),
              'お気に入りに追加しました',
              'お気に入りに追加できませんでした',
            ),
    _ =>
      channel.isMuting
          ? (
              'unmute',
              () => support.unmuteChannel(id),
              'ミュートを解除しました',
              'ミュート解除に失敗しました',
            )
          : ('mute', () => support.muteChannel(id), 'ミュートしました', 'ミュートに失敗しました'),
  };
  try {
    await run();
  } catch (e, st) {
    reportOpFailure(
      tagKey: 'channel.op',
      operation: operation,
      error: e,
      stackTrace: st,
      account: account,
    );
    messenger.showSnackBar(
      SnackBar(content: Text('$failed\n${summarizeOpError(e)}')),
    );
    return;
  }
  // ⚠ 通信の間に行が破棄されていると `ref` は触れないので、コンテナへ当てる
  // （PR #1285 の Codex P2）。飛ばすと、成功したのに一覧が古いまま残る。
  invalidateChannelsIn(container);
  messenger.showSnackBar(SnackBar(content: Text(done)));
}
