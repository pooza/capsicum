import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/cursor_paged_list_view.dart';

/// フォロー中のハッシュタグ一覧 (#1070)。
///
/// ⚠⚠ **これが無いと解除の導線が「そのタグのタイムラインを開く」経路にしか
/// 無い。**何をフォローしたか忘れると解除する手段が事実上なくなる。
/// [ModerationListScreen]（#1039・ミュートすると相手が TL から消えるので
/// 解除できない）と**同じ構造の問題**なので、様式を揃えてある。
///
/// ⚠ **Mastodon 固有。**Misskey はハッシュタグのフォローを持たないので
/// アダプター側が空を返し、この画面は「フォロー中のタグはありません」になる。
///
/// ⚠ **ページングの骨格は [CursorPagedListView] が持つ (#1083-A)。**ここが足すのは
/// 解除ボタンとその途中状態だけ。⚠ **以前はプリフェッチ閾値を独自に 400 に
/// していたが、理由の記載が無かった**ので集約時に多数派の 600 へ揃えた。
class FollowedHashtagsScreen extends ConsumerStatefulWidget {
  const FollowedHashtagsScreen({super.key});

  @override
  ConsumerState<FollowedHashtagsScreen> createState() =>
      _FollowedHashtagsScreenState();
}

class _FollowedHashtagsScreenState
    extends ConsumerState<FollowedHashtagsScreen> {
  /// ⚠ **ページサイズは fetcher 側に閉じ込める (#1083-A)。**他の 2 本は
  /// 「渡す側が `limit` ごと持つ」形なので揃えた。
  static const _pageSize = 40;

  /// 解除済みのタグ。⚠ **行を消さない**（#1039 と同じ理由）。サーバー側の
  /// 反映にラグがあると取り直しで復活し、「解除できていない」に見える。
  final _released = <String>{};
  final _inFlight = <String>{};

  /// 解除済み / 処理中の記録がどのアカウントのものか。
  ///
  /// ⚠ アカウントを切り替えたら捨てる。同じ名前のタグが切替先にもあると、
  /// 前のアカウントでの「解除しました」が出てしまう。
  String? _recordedFor;

  Future<({List<String> items, String? nextCursor})> _fetch(
    HashtagSupport? support,
    String? cursor,
  ) async {
    // ⚠ support が null になるのは HashtagSupport を持たないアダプターのとき。
    // 空で返して「フォロー中のハッシュタグはありません」に落とす（失敗では
    // ない）。Misskey は持っているが、アダプター側が空を返す（クラス doc）。
    if (support == null) return (items: <String>[], nextCursor: null);
    final result = await support.getFollowedHashtags(
      query: TimelineQuery(maxId: cursor, limit: _pageSize),
    );
    return (items: result.tags, nextCursor: result.nextCursor);
  }

  Future<void> _unfollow(HashtagSupport? support, String tag) async {
    if (support == null) return;
    if (_inFlight.contains(tag) || _released.contains(tag)) return;

    // ⚠ **await をまたぐ前に捕まえる**（#1064 と同型）。
    final messenger = ScaffoldMessenger.of(context);
    final account = ref.read(currentAccountProvider);
    // ⚠ 切替の前に始めた解除の完了を、切替後の表示に書き込ませない
    // （v1.64 のリリース PR の Codex P2）。
    final startedFor = _recordedFor;

    setState(() => _inFlight.add(tag));
    try {
      await support.unfollowHashtag(tag);
      if (!mounted || startedFor != _recordedFor) return;
      setState(() {
        _inFlight.remove(tag);
        _released.add(tag);
      });
      messenger.showSnackBar(SnackBar(content: Text('#$tag のフォローを解除しました')));
    } catch (e, st) {
      reportOpFailure(
        // ⚠ **キーは「op の系統」で、対象ではない (#1083-E)。**`hashtag.followed`
        // は「フォロー中のタグ」という**対象**を名前にしていた。何をしたかは
        // operation が持つ。
        tagKey: 'hashtag.op',
        operation: 'unfollow',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (!mounted || startedFor != _recordedFor) return;
      setState(() => _inFlight.remove(tag));
      messenger.showSnackBar(const SnackBar(content: Text('フォローの解除に失敗しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // ⚠ **`ref.watch` で build に追随させる (#1083-F の取りこぼし・v1.64 の
    // リリース前レビュー)。**兄弟の [FollowRequestsScreen] /
    // [ModerationListScreen] は #1083-F で直したのに、ここだけ `ref.read` の
    // getter のままだった。画面を開いたままアカウントを切り替えると、表示は
    // 前のアカウントの一覧のまま、追加読み込みと**解除は切替後のアカウントへ
    // 飛んでいた**（別アカウントのタグを解除しうる）。
    final adapter = ref.watch(currentAdapterProvider);
    final support = adapter is HashtagSupport
        ? adapter as HashtagSupport
        : null;
    final accountKey = ref.watch(currentAccountProvider)?.key.toStorageKey();
    if (_recordedFor != accountKey) {
      _recordedFor = accountKey;
      _released.clear();
      _inFlight.clear();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('フォロー中のハッシュタグ')),
      body: BottomSafeArea(
        child: CursorPagedListView<String>(
          // 切替後に前のサーバーの一覧が残らないよう、アカウントで作り直す。
          key: ValueKey(accountKey),
          debugLabel: 'FollowedHashtagsScreen',
          // 一覧の取得失敗を観測する (#1083-D)。解除操作は上の 'hashtag.op'。
          tagKey: 'hashtag.list',
          fetcher: (cursor) => _fetch(support, cursor),
          emptyMessage: 'フォロー中のハッシュタグはありません',
          itemBuilder: (context, tag) => ListTile(
            leading: const Icon(Icons.tag),
            title: Text('#$tag'),
            // 一覧からタグのタイムラインへ飛べる（完了条件のひとつ）。
            onTap: () => context.push('/hashtag/$tag'),
            trailing: _trailing(support, tag),
          ),
        ),
      ),
    );
  }

  Widget _trailing(HashtagSupport? support, String tag) {
    if (_released.contains(tag)) return const Text('解除しました');
    if (_inFlight.contains(tag)) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return TextButton(
      onPressed: () => _unfollow(support, tag),
      child: const Text('フォロー解除'),
    );
  }
}
