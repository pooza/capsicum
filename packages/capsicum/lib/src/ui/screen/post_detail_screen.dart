import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/is_cat_provider.dart';
import '../../provider/preferences_provider.dart';
import '../util/keyboard_list_navigation.dart';
import '../widget/post_tile.dart';

class PostDetailScreen extends ConsumerStatefulWidget {
  final Post post;

  const PostDetailScreen({super.key, required this.post});

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen>
    with KeyboardListNavigation {
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  // ↑ ↓ キーで辿る対象 (#849)。描画中のスレッドと同じリストに揃える。
  List<Post> _thread = const [];

  Post get post => widget.post;

  @override
  ItemScrollController get keyboardListScrollController =>
      _itemScrollController;

  @override
  ItemPositionsListener get keyboardListPositionsListener =>
      _itemPositionsListener;

  @override
  int get keyboardListItemCount => _thread.length;

  /// ↑ ↓ キーの対象を空にする (#849 followup)。
  ///
  /// 対象リストは `data:` ブランチでしか代入していないので、投稿アクションで
  /// スレッドを invalidate した後の再取得が失敗すると、**前のスレッドが対象として
  /// 残り続ける**。キーハンドラを張る [Focus] はその間も生きているため、↑ ↓ と
  /// Enter で画面に出ていない投稿を開けてしまう（ホーム側と同型 / home_screen の
  /// 同名メソッド参照）。
  void _clearKeyboardTargets() {
    _thread = const [];
    if (keyboardSelectedIndex == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) resetKeyboardSelection();
    });
  }

  /// 未選択から ↑ ↓ を押したときは、開いた時点でアンカーしている対象リプライ
  /// (#711) から辿り始める。
  @override
  int get keyboardListInitialIndex =>
      _thread.isEmpty ? 0 : _targetIndex(_thread);

  @override
  void onKeyboardListActivate(int index) {
    if (index >= _thread.length) return;
    final selected = _thread[index];
    // 対象リプライ自身（いま開いているスレッドの主役）は開き直さない。
    if (selected.id == post.id) return;
    context.push('/post', extra: selected);
  }

  /// スレッド内で対象リプライ（タップした投稿）が並ぶ index。見つからない
  /// 場合は最後尾を返す（#711 のフォールバック）。
  int _targetIndex(List<Post> thread) {
    final i = thread.indexWhere((p) => p.id == post.id);
    return i >= 0 ? i : thread.length - 1;
  }

  void _jumpTo(int index) {
    if (!_itemScrollController.isAttached) return;
    _itemScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _jumpToTop() => _jumpTo(0);

  void _jumpToBottom() {
    final length = ref.read(_threadProvider(post.id)).asData?.value.length ?? 0;
    if (length > 0) _jumpTo(length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final threadFuture = ref.watch(_threadProvider(post.id));
    // 長いスレッドでのみジャンプ導線を出す（1 件だけならスクロール不要）。
    final showJump = (threadFuture.asData?.value.length ?? 0) > 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text('スレッド'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _buildBody(context, ref, threadFuture),
      floatingActionButton: showJump
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'thread_jump_top',
                  tooltip: '先頭へ',
                  onPressed: _jumpToTop,
                  child: const Icon(Icons.keyboard_arrow_up),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'thread_jump_bottom',
                  tooltip: '末尾へ',
                  onPressed: _jumpToBottom,
                  child: const Icon(Icons.keyboard_arrow_down),
                ),
              ],
            )
          : null,
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Post>> threadFuture,
  ) {
    final storageKey = ref.watch(currentAccountProvider)?.key.toStorageKey();
    final bgPath = storageKey != null
        ? ref.watch(backgroundImageProvider(storageKey))
        : null;
    final bgOpacity = storageKey != null
        ? ref.watch(backgroundOpacityProvider(storageKey))
        : defaultBackgroundOpacity;

    Widget body = threadFuture.when(
      data: (thread) {
        // ↑ ↓ キーの対象を、いま描画しているものと同じリストに揃える (#849)。
        _thread = thread;
        return ScrollablePositionedList.separated(
          itemScrollController: _itemScrollController,
          itemPositionsListener: _itemPositionsListener,
          // 開いた時点で対象リプライの位置へアンカーする (#711)。見つからない
          // ときは最後尾（フォールバック）。root(0) のときはそのまま先頭表示。
          initialScrollIndex: thread.isEmpty ? 0 : _targetIndex(thread),
          itemCount: thread.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final p = thread[index];
            final isTarget = p.id == post.id;
            return Container(
              color: isTarget
                  ? Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : null,
              child: PostTile(
                post: p,
                tappable: !isTarget,
                initialExpanded: isTarget,
                selectable: true,
                selected: keyboardSelectedIndex == index,
                onActionCompleted: () =>
                    ref.invalidate(_threadProvider(post.id)),
              ),
            );
          },
        );
      },
      loading: () {
        _clearKeyboardTargets();
        return const Center(child: CircularProgressIndicator());
      },
      error: (error, stack) {
        _clearKeyboardTargets();
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('スレッドの読み込みに失敗しました\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(_threadProvider(post.id)),
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
        );
      },
    );

    // スレッドには入力欄が無いので、本体をそのまま包んで ↑ ↓ を受ける (#849)。
    body = wrapKeyboardListNavigation(child: body);

    if (bgPath != null) {
      body = Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: FileImage(File(bgPath)),
            fit: BoxFit.cover,
            opacity: bgOpacity,
          ),
        ),
        child: body,
      );
    }

    return body;
  }
}

final _threadProvider = FutureProvider.autoDispose.family<List<Post>, String>((
  ref,
  postId,
) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null) return [];
  final thread = await adapter.getThread(postId);
  return ref.read(isCatEnricherProvider).enrichPosts(thread);
});
