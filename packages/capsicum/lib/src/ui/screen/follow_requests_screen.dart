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

  /// [_handled] / [_inFlight] がどのアカウントのものか。
  ///
  /// ⚠ **アカウントを切り替えたら捨てる**（v1.64 のリリース PR の Codex P2）。
  /// key で作り直すのは一覧だけで、この State は残る。user id はサーバーごとの
  /// 値なので、切替先で同じ id が「承認しました」「処理中」のまま操作できなく
  /// なる。⚠ 切替の前に始めた操作の完了も、切替後の表示に書き込ませない。
  String? _recordedFor;

  /// ⚠ **[support] は build 時に解決したものを受け取る (#1083-F)。**
  /// 以前は `ref.read` の getter を取得・処理・build から個別に呼んでいたので、
  /// (a) アカウント切替で `build()` が追随せず、(b) **サーバー A で取った id を
  /// 切替後のサーバー B へ承認・拒否で投げうる**形だった。
  Future<({List<User> users, String? nextCursor})> _fetch(
    FollowRequestSupport support,
    String? cursor,
  ) =>
      support.getFollowRequests(query: TimelineQuery(maxId: cursor, limit: 20));

  Future<void> _handle(
    FollowRequestSupport support,
    User user,
    _Handled action,
  ) async {
    if (_inFlight.contains(user.id) || _handled.containsKey(user.id)) return;

    // ⚠ **await をまたぐ前に捕まえる**（#1064 と同型）。
    final messenger = ScaffoldMessenger.of(context);
    final account = ref.read(currentAccountProvider);
    final startedFor = _recordedFor;

    setState(() => _inFlight.add(user.id));
    try {
      if (action == _Handled.authorized) {
        await support.authorizeFollowRequest(user.id);
      } else {
        await support.rejectFollowRequest(user.id);
      }
      if (!mounted || startedFor != _recordedFor) return;
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
        // ⚠ **ドット付きの `<領域>.op` に揃える (#1083-E)。**既存 16 箇所で
        // ここだけドットが無かった。
        tagKey: 'follow_request.op',
        operation: action == _Handled.authorized ? 'authorize' : 'reject',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (!mounted || startedFor != _recordedFor) return;
      setState(() => _inFlight.remove(user.id));
      messenger.showSnackBar(const SnackBar(content: Text('リクエストの処理に失敗しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // ⚠ **`ref.watch` で build に追随させる (#1083-F)。**同型の
    // [ModerationListScreen] は watch なのに、ここだけ `ref.read` の getter を
    // build から呼んでいて、**画面を開いたままのアカウント切替で再構築され
    // なかった**。切替後に前のサーバーの一覧が残らないよう `key` も置く。
    final adapter = ref.watch(currentAdapterProvider);
    final support = adapter is FollowRequestSupport
        ? adapter as FollowRequestSupport
        : null;
    final accountKey = ref.watch(currentAccountProvider)?.key.toStorageKey();
    if (_recordedFor != accountKey) {
      _recordedFor = accountKey;
      _handled.clear();
      _inFlight.clear();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('フォローリクエスト')),
      body: support == null
          ? const Center(child: Text('このサーバーでは利用できません'))
          : UserListView(
              key: ValueKey(accountKey),
              fetcher: (cursor) => _fetch(support, cursor),
              emptyMessage: '未処理のフォローリクエストはありません',
              trailingBuilder: (user) => _trailing(support, user),
            ),
    );
  }

  Widget _trailing(FollowRequestSupport support, User user) {
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
          onPressed: () => _handle(support, user, _Handled.rejected),
          child: const Text('拒否'),
        ),
        FilledButton(
          onPressed: () => _handle(support, user, _Handled.authorized),
          child: const Text('承認'),
        ),
      ],
    );
  }
}
