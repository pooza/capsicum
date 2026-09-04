import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/exception_scrub.dart';
import '../widget/bottom_safe_area.dart';

/// フォロー中のハッシュタグ一覧 (#1070)。
///
/// ⚠⚠ **これが無いと解除の導線が「そのタグのタイムラインを開く」経路にしか
/// 無い。**何をフォローしたか忘れると解除する手段が事実上なくなる。
/// [ModerationListScreen]（#1039・ミュートすると相手が TL から消えるので
/// 解除できない）と**同じ構造の問題**なので、様式を揃えてある。
///
/// ⚠ **Mastodon 固有。**Misskey はハッシュタグのフォローを持たないので
/// アダプター側が空を返し、この画面は「フォロー中のタグはありません」になる。
class FollowedHashtagsScreen extends ConsumerStatefulWidget {
  const FollowedHashtagsScreen({super.key});

  @override
  ConsumerState<FollowedHashtagsScreen> createState() =>
      _FollowedHashtagsScreenState();
}

class _FollowedHashtagsScreenState
    extends ConsumerState<FollowedHashtagsScreen> {
  static const _pageSize = 40;

  final _scrollController = ScrollController();
  List<String> _tags = [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  /// 解除済みのタグ。⚠ **行を消さない**（#1039 と同じ理由）。サーバー側の
  /// 反映にラグがあると取り直しで復活し、「解除できていない」に見える。
  final _released = <String>{};
  final _inFlight = <String>{};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  HashtagSupport? get _support {
    final adapter = ref.read(currentAdapterProvider);
    return adapter is HashtagSupport ? adapter as HashtagSupport : null;
  }

  Future<void> _load() async {
    final support = _support;
    if (support == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final result = await support.getFollowedHashtags(
        query: const TimelineQuery(limit: _pageSize),
      );
      if (!mounted) return;
      setState(() {
        _tags = result.tags;
        _nextCursor = result.nextCursor;
        _loading = false;
        _hasMore = result.nextCursor != null && result.tags.length >= _pageSize;
      });
    } catch (e) {
      debugLogException('FollowedHashtagsScreen load error', e);
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _tags.isEmpty) return;
    final support = _support;
    if (support == null) return;
    setState(() => _loadingMore = true);
    try {
      final result = await support.getFollowedHashtags(
        query: TimelineQuery(maxId: _nextCursor, limit: _pageSize),
      );
      if (!mounted) return;
      setState(() {
        _tags = [..._tags, ...result.tags];
        _nextCursor = result.nextCursor;
        _loadingMore = false;
        _hasMore = result.nextCursor != null && result.tags.length >= _pageSize;
      });
    } catch (e) {
      debugLogException('FollowedHashtagsScreen loadMore error', e);
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _unfollow(String tag) async {
    final support = _support;
    if (support == null) return;
    if (_inFlight.contains(tag) || _released.contains(tag)) return;

    // ⚠ **await をまたぐ前に捕まえる**（#1064 と同型）。
    final messenger = ScaffoldMessenger.of(context);
    final account = ref.read(currentAccountProvider);

    setState(() => _inFlight.add(tag));
    try {
      await support.unfollowHashtag(tag);
      if (!mounted) return;
      setState(() {
        _inFlight.remove(tag);
        _released.add(tag);
      });
      messenger.showSnackBar(SnackBar(content: Text('#$tag のフォローを解除しました')));
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'hashtag.followed',
        operation: 'unfollow',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (!mounted) return;
      setState(() => _inFlight.remove(tag));
      messenger.showSnackBar(const SnackBar(content: Text('フォローの解除に失敗しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('フォロー中のハッシュタグ')),
      body: BottomSafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _tags.isEmpty
            ? const Center(child: Text('フォロー中のハッシュタグはありません'))
            : RefreshIndicator(
                onRefresh: () async {
                  setState(() => _loading = true);
                  await _load();
                },
                child: ListView.separated(
                  controller: _scrollController,
                  itemCount: _tags.length + (_loadingMore ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index >= _tags.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final tag = _tags[index];
                    return ListTile(
                      leading: const Icon(Icons.tag),
                      title: Text('#$tag'),
                      // 一覧からタグのタイムラインへ飛べる（完了条件のひとつ）。
                      onTap: () => context.push('/hashtag/$tag'),
                      trailing: _trailing(tag),
                    );
                  },
                ),
              ),
      ),
    );
  }

  Widget _trailing(String tag) {
    if (_released.contains(tag)) return const Text('解除しました');
    if (_inFlight.contains(tag)) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return TextButton(
      onPressed: () => _unfollow(tag),
      child: const Text('フォロー解除'),
    );
  }
}
