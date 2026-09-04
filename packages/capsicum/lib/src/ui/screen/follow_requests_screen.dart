import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/user_acct.dart';
import 'user_list_screen.dart';

/// 自分宛のフォローリクエスト一覧 (#1040)。
///
/// ⚠ **通知の型はあるのに操作が無かった。**「フォローリクエストが来ました」は
/// 通知画面に出るのに、そこから承認も拒否もできず、鍵アカウントのユーザーは
/// WebUI を開くしかなかった。
///
/// ⚠ **通知タイルの導線だけでは足りない。**通知は流れるので、溜まった申請を
/// まとめて処理する行き先が要る。#805 の様式では独立画面。
class FollowRequestsScreen extends ConsumerStatefulWidget {
  const FollowRequestsScreen({super.key});

  @override
  ConsumerState<FollowRequestsScreen> createState() =>
      _FollowRequestsScreenState();
}

/// 処理済みの申請に対する結果表示 (#1040)。
enum _Handled { authorized, rejected }

class _FollowRequestsScreenState extends ConsumerState<FollowRequestsScreen> {
  /// 処理済みの申請。⚠ **行を消さない**（#1039 / #1070 と同じ理由）。
  /// サーバー側の反映にラグがあると取り直しで復活し、「処理できていない」に
  /// 見える。行は残して結果を描き分ける。
  final _handled = <String, _Handled>{};
  final _inFlight = <String>{};

  FollowRequestSupport? get _support {
    final adapter = ref.read(currentAdapterProvider);
    return adapter is FollowRequestSupport
        ? adapter as FollowRequestSupport
        : null;
  }

  Future<({List<User> users, String? nextCursor})> _fetch(
    String? cursor,
  ) async {
    final support = _support;
    if (support == null) return (users: <User>[], nextCursor: null);
    return support.getFollowRequests(
      query: TimelineQuery(maxId: cursor, limit: 20),
    );
  }

  Future<void> _handle(User user, _Handled action) async {
    final support = _support;
    if (support == null) return;
    if (_inFlight.contains(user.id) || _handled.containsKey(user.id)) return;

    // ⚠ **await をまたぐ前に捕まえる**（#1064 と同型）。
    final messenger = ScaffoldMessenger.of(context);
    final account = ref.read(currentAccountProvider);

    setState(() => _inFlight.add(user.id));
    try {
      if (action == _Handled.authorized) {
        await support.authorizeFollowRequest(user.id);
      } else {
        await support.rejectFollowRequest(user.id);
      }
      if (!mounted) return;
      setState(() {
        _inFlight.remove(user.id);
        _handled[user.id] = action;
      });
      final label = action == _Handled.authorized ? '承認' : '拒否';
      messenger.showSnackBar(
        SnackBar(content: Text('@${userAcct(user)} のリクエストを$labelしました')),
      );
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'follow_request',
        operation: action == _Handled.authorized ? 'authorize' : 'reject',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (!mounted) return;
      setState(() => _inFlight.remove(user.id));
      messenger.showSnackBar(const SnackBar(content: Text('リクエストの処理に失敗しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('フォローリクエスト')),
      body: _support == null
          ? const Center(child: Text('このサーバーでは利用できません'))
          : UserListView(
              fetcher: _fetch,
              emptyMessage: '未処理のフォローリクエストはありません',
              trailingBuilder: _trailing,
            ),
    );
  }

  Widget _trailing(User user) {
    final handled = _handled[user.id];
    if (handled != null) {
      return Text(handled == _Handled.authorized ? '承認しました' : '拒否しました');
    }
    if (_inFlight.contains(user.id)) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: () => _handle(user, _Handled.rejected),
          child: const Text('拒否'),
        ),
        FilledButton(
          onPressed: () => _handle(user, _Handled.authorized),
          child: const Text('承認'),
        ),
      ],
    );
  }
}
