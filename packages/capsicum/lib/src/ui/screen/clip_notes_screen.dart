import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/clip_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/oauth_scope_error.dart';
import '../util/scroll_thresholds.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/clip_actions_sheet.dart';
import '../widget/post_tile.dart';
import '../widget/retry_error_view.dart';

class ClipNotesScreen extends ConsumerStatefulWidget {
  final String clipId;
  final String? clipName;

  const ClipNotesScreen({super.key, required this.clipId, this.clipName});

  @override
  ConsumerState<ClipNotesScreen> createState() => _ClipNotesScreenState();
}

class _ClipNotesScreenState extends ConsumerState<ClipNotesScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (shouldLoadMore(_scrollController.position)) {
      ref.read(clipNotesProvider(widget.clipId).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(clipNotesProvider(widget.clipId));
    // 自分のクリップなら、操作（編集・削除）を出す (#1050)。⚠ 一覧に無い
    // （ほかの人の公開クリップ・まだ読めていない）ときは出さない。
    final canManage =
        ref.watch(currentAdapterProvider) is ClipManagementSupport;
    NoteClip? clip;
    for (final c
        in ref.watch(clipsProvider).valueOrNull ?? const <NoteClip>[]) {
      if (c.id == widget.clipId) clip = c;
    }

    return Scaffold(
      appBar: AppBar(
        // ⚠ 編集で名前を変えたら追随させる（一覧を取り直すので）。
        title: Text(clip?.name ?? widget.clipName ?? 'クリップ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // ほかの人のクリップなら、お気に入りに入れる / 外す (#1377)。
          if (clip == null) _ClipFavoriteButton(clipId: widget.clipId),
          if (canManage && clip != null)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: 'クリップの操作',
              onPressed: () async {
                final deleted = await showClipActions(context, ref, clip!);
                if (deleted && context.mounted) Navigator.of(context).pop();
              },
            ),
        ],
      ),
      body: BottomSafeArea(
        child: timeline.when(
          data: (state) => state.posts.isEmpty
              ? const Center(child: Text('投稿がありません'))
              : RefreshIndicator(
                  onRefresh: () =>
                      ref.refresh(clipNotesProvider(widget.clipId).future),
                  child: ListView.separated(
                    controller: _scrollController,
                    itemCount:
                        state.posts.length + (state.isLoadingMore ? 1 : 0),
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index >= state.posts.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      return PostTile(post: state.posts[index]);
                    },
                  ),
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => RetryErrorView(
            message: '読み込みに失敗しました',
            isRetrying: timeline.isLoading,
            onRetry: () => ref.invalidate(clipNotesProvider(widget.clipId)),
          ),
        ),
      ),
    );
  }
}

/// ほかの人のクリップを、お気に入りに入れる / 外す (#1377)。
///
/// - 自分のクリップ・状態が読めないとき（[clipDetailProvider] が null か失敗）は
///   出さない
/// - 押したらすぐ見た目を変え（楽観更新）、失敗したら戻す（ギャラリーのいいねと
///   同じ形）。既に入っていた / もう外れていたは、アダプターが成功にする
/// - 旧トークン（`write:clip-favorite` が無い）の 403 は、再ログインを案内する
class _ClipFavoriteButton extends ConsumerStatefulWidget {
  const _ClipFavoriteButton({required this.clipId});

  final String clipId;

  @override
  ConsumerState<_ClipFavoriteButton> createState() =>
      _ClipFavoriteButtonState();
}

class _ClipFavoriteButtonState extends ConsumerState<_ClipFavoriteButton> {
  /// 押したあとの値。null なら [clipDetailProvider] の値を出す。
  bool? _favorited;
  bool _busy = false;

  Future<void> _toggle(bool wasFavorited) async {
    if (_busy) return;
    final raw = ref.read(currentAdapterProvider);
    if (raw is! ClipFavoriteSupport) return;
    final support = raw as ClipFavoriteSupport;
    final account = ref.accountForReport;
    final messenger = ScaffoldMessenger.of(context);
    // ⚠ await の前に取る。応答の前に画面を閉じると、破棄した State の ref は
    // StateError を投げ、成功したのに「更新できませんでした」と出てしまう
    // （リリース前レビュー・v2.15）。デッキのカラムのスコープもここで決まる。
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      _busy = true;
      _favorited = !wasFavorited;
    });
    try {
      if (wasFavorited) {
        await support.unfavoriteClip(widget.clipId);
      } else {
        await support.favoriteClip(widget.clipId);
      }
      // お気に入りの一覧を取り直させる（次に開いたとき揃うように）。
      container.invalidate(favoriteClipsProvider);
    } catch (e, st) {
      if (mounted) setState(() => _favorited = wasFavorited);
      if (e is ClipNotFound) {
        messenger.showSnackBar(
          const SnackBar(content: Text('このクリップはもう見られません')),
        );
      } else if (isOAuthScopeError(e)) {
        messenger.showSnackBar(
          const SnackBar(content: Text(oauthScopeErrorMessage)),
        );
      } else {
        reportOpFailure(
          tagKey: 'clip.op',
          operation: wasFavorited ? 'unfavorite' : 'favorite',
          error: e,
          stackTrace: st,
          account: account,
        );
        // 言い回しはチャンネルのお気に入り（channel_actions_sheet.dart）に揃える。
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              wasFavorited ? 'お気に入りから外せませんでした' : 'お気に入りに追加できませんでした',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(clipDetailProvider(widget.clipId)).valueOrNull;
    final me = ref.watch(currentAccountProvider)?.user.id;
    // ⚠ 自分のクリップには出さない（一覧に無くても、持ち主が自分なら自分のもの）。
    if (detail == null || detail.userId == null || detail.userId == me) {
      return const SizedBox.shrink();
    }
    final favorited = _favorited ?? detail.isFavorited ?? false;
    return IconButton(
      key: const ValueKey('clip-favorite'),
      icon: Icon(favorited ? Icons.star : Icons.star_border),
      tooltip: favorited ? 'お気に入りから外す' : 'お気に入りに追加',
      onPressed: _busy ? null : () => _toggle(favorited),
    );
  }
}
