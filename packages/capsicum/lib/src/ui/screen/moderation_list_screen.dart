import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/user_acct.dart';
import 'user_list_screen.dart';

/// ブロック / ミュート中のユーザー一覧 (#1039)。
///
/// ⚠⚠ **ミュートは「相手が TL から出てこなくなる」操作なので、一覧が無いと
/// 解除の導線が構造的に塞がる。**相手のプロフィールへ辿り着く手段が残らず、
/// うろ覚えだと詰む。capsicum は「見たくないものを見ないようにする道具は
/// 読む側に提供する」方針（docs/CLAUDE.md）なので、外し方が無いのは片肺。
///
/// ブロックは相手のプロフィールから解除できるので詰まりはしないが、
/// 「自分が今誰をブロックしているか」を確認する手段が無い点は同じ。
class ModerationListScreen extends ConsumerWidget {
  const ModerationListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adapter = ref.watch(currentAdapterProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ブロックとミュート'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'ブロック'),
              Tab(text: 'ミュート'),
            ],
          ),
        ),
        body: adapter is! FollowSupport
            ? const Center(child: Text('このサーバーでは利用できません'))
            : TabBarView(
                children: [
                  _ModerationTab(
                    key: const ValueKey('blocks'),
                    kind: _ModerationKind.block,
                  ),
                  _ModerationTab(
                    key: const ValueKey('mutes'),
                    kind: _ModerationKind.mute,
                  ),
                ],
              ),
      ),
    );
  }
}

enum _ModerationKind {
  block(
    label: 'ブロック',
    empty: 'ブロック中のユーザーはいません',
    releaseLabel: 'ブロックを解除',
    tag: 'moderation.blocks',
  ),
  mute(
    label: 'ミュート',
    empty: 'ミュート中のユーザーはいません',
    releaseLabel: 'ミュートを解除',
    tag: 'moderation.mutes',
  );

  const _ModerationKind({
    required this.label,
    required this.empty,
    required this.releaseLabel,
    required this.tag,
  });

  final String label;
  final String empty;
  final String releaseLabel;
  final String tag;
}

class _ModerationTab extends ConsumerStatefulWidget {
  final _ModerationKind kind;

  const _ModerationTab({super.key, required this.kind});

  @override
  ConsumerState<_ModerationTab> createState() => _ModerationTabState();
}

class _ModerationTabState extends ConsumerState<_ModerationTab> {
  /// 解除済みの id。⚠ **一覧を丸ごと取り直さない。**サーバー側の反映に
  /// ラグがあると解除した相手がまた出てきて「解除できていない」に見える。
  /// 行を消す代わりに、解除済みとして描き分ける。
  final _released = <String>{};

  /// 解除の実行中。二度押しで同じ相手へ 2 回投げないようにする。
  final _inFlight = <String>{};

  Future<({List<User> users, String? nextCursor})> _fetch(
    String? cursor,
  ) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! FollowSupport) {
      return (users: <User>[], nextCursor: null);
    }
    final follow = adapter as FollowSupport;
    final query = TimelineQuery(maxId: cursor, limit: 20);
    return widget.kind == _ModerationKind.block
        ? follow.getBlockedUsers(query: query)
        : follow.getMutedUsers(query: query);
  }

  Future<void> _release(User user) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! FollowSupport) return;
    if (_inFlight.contains(user.id) || _released.contains(user.id)) return;

    // ⚠ **await をまたぐ前に捕まえる (#1064 と同型)。**シート / タブが閉じた
    // あとに `ref.read` / `ScaffoldMessenger.of` を評価すると、成功していても
    // 失敗の見た目になったり例外で消えたりする。
    final messenger = ScaffoldMessenger.of(context);
    final follow = adapter as FollowSupport;
    final account = ref.read(currentAccountProvider);

    setState(() => _inFlight.add(user.id));
    try {
      if (widget.kind == _ModerationKind.block) {
        await follow.unblockUser(user.id);
      } else {
        await follow.unmuteUser(user.id);
      }
      if (!mounted) return;
      setState(() {
        _inFlight.remove(user.id);
        _released.add(user.id);
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('@${userAcct(user)} の${widget.kind.label}を解除しました'),
        ),
      );
    } catch (e, st) {
      reportOpFailure(
        tagKey: widget.kind.tag,
        operation: 'release',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (!mounted) return;
      setState(() => _inFlight.remove(user.id));
      messenger.showSnackBar(
        SnackBar(content: Text('${widget.kind.label}の解除に失敗しました')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return UserListView(
      fetcher: _fetch,
      emptyMessage: widget.kind.empty,
      trailingBuilder: (user) {
        if (_released.contains(user.id)) {
          return const Text('解除しました');
        }
        if (_inFlight.contains(user.id)) {
          return const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        }
        return TextButton(
          onPressed: () => _release(user),
          child: Text(widget.kind.releaseLabel),
        );
      },
    );
  }
}
