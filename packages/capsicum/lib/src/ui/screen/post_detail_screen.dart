import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/is_cat_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../util/keyboard_list_navigation.dart';
import '../util/op_error.dart';
import '../util/post_actions.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/desktop_menu_model.dart';
import '../widget/post_tile.dart';
import '../widget/retry_error_view.dart';
import '../widget/screen_menu.dart';

/// ↑ / ↓ ジャンプ FAB のぶん、スクロール本体の下端に確保する高さ (#1059)。
///
/// FAB は `Scaffold.floatingActionButton` で **body の上に浮く**ので、body を
/// inset しても避けられない。スクロール範囲に足しておかないと、最下部まで
/// 送っても最後の投稿がボタンの下に残り、**逃がす手段が無い**。
///
/// 内訳: `FloatingActionButton.small` が 40 で 2 つ、間隔 8、`Scaffold` が
/// FAB に与える既定マージン 16。
///
/// ⚠ **[BottomSafeArea] の inset とは別物。**あちらはシステムのナビゲーション
/// バー (#1037)、こちらはアプリ自身のボタン。**両方要る。**片方で足りている
/// ように見えるのは、たまたま投稿がそこまで届いていないときだけ。
const double _jumpFabReservedHeight = 40 * 2 + 8 + 16;

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
  /// Enter で画面に出ていない投稿を開けてしまう。選択の後始末は mixin の
  /// [resetKeyboardSelectionAfterFrame] に集約した (#928)。
  void _clearKeyboardTargets() {
    _thread = const [];
    resetKeyboardSelectionAfterFrame();
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

  void _reload() => ref.invalidate(_threadProvider(post.id));

  /// ↑ ↓ で辿っている投稿 (#849)。未選択なら null。
  ///
  /// **メニューはこの選択に乗る**（#943）。「どの投稿への操作か」を表す状態が
  /// 画面に既にあるので、新しく増やさずに済む。
  Post? get _selectedPost {
    final index = keyboardSelectedIndex;
    if (index == null || index < 0 || index >= _thread.length) return null;
    return _thread[index];
  }

  PostActionRunner _runner() => PostActionRunner(
    ref: ref,
    messenger: ScaffoldMessenger.of(context),
    // 実行後はスレッドを取り直す。カウンタ表示や自分のリノート行の増減が
    // タイルへ反映される。
    onActionCompleted: _reload,
  );

  /// 選択中の投稿に対してアクションを起こす。
  ///
  /// ⚠ **判定は [PostActionAvailability] を通す。** メニュー項目の出し分けと
  /// 実行側で条件が割れると、無効に見えるのに走る / その逆が起きる。
  ///
  /// ⚠ **[allowed] を必須の引数にしてあるのは、その保証をコードで持たせるため**
  /// (#982)。以前はこの doc が「通す」と名乗っているだけで、実行側は
  /// `canBoost` / `canReply` / `canQuote` を見ずに走っていた。いまはメニューが
  /// `onSelected: null` で無効化しているので到達不能だが、**ショートカット等の
  /// 別入口が付いた瞬間に顕在化する**形だった。
  void _withSelected(
    bool Function(PostActionAvailability a) allowed,
    void Function(PostActionAvailability a) action,
  ) {
    final selected = _selectedPost;
    if (selected == null) return;
    final availability = PostActionAvailability.of(ref, selected);
    if (!allowed(availability)) return;
    action(availability);
  }

  void _replyToSelected() => _withSelected(
    (a) => a.canReply,
    (a) => context.push('/compose', extra: {'replyTo': a.targetPost}),
  );

  void _quoteSelected() => _withSelected(
    (a) => a.canQuote,
    (a) => context.push('/compose', extra: {'quoteTo': a.targetPost}),
  );

  void _boostSelected() => _withSelected((a) => a.canBoost, (a) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    // 公開範囲を選ぶ chip はシート側の作り込みなので、メニューからは既定
    // （チャンネル指定なし・元の公開範囲）で実行する。
    _runner().run(
      () => adapter.repeatPost(a.targetPost.id),
      '${a.boostLabel}しました',
    );
  });

  void _unboostSelected() => _withSelected((a) => a.canUnrepeat, (a) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    _runner().unrepeat(
      adapter: adapter,
      outerPost: a.outerPost,
      targetPost: a.targetPost,
      isOwnRenote: a.isOwnRenote,
      boostLabel: a.boostLabel,
    );
  });

  void _favoriteSelected() => _withSelected((a) => a.canFavorite, (a) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! FavoriteSupport) return;
    _runner().run(
      () => (adapter as FavoriteSupport).favoritePost(a.targetPost.id),
      'お気に入りに追加しました',
    );
  });

  void _bookmarkSelected() => _withSelected((a) => a.canBookmark, (a) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! BookmarkSupport) return;
    _runner().run(
      () => (adapter as BookmarkSupport).bookmarkPost(a.targetPost.id),
      '${a.bookmarkLabel}に追加しました',
    );
  });

  @override
  Widget build(BuildContext context) {
    final threadFuture = ref.watch(_threadProvider(post.id));
    // 長いスレッドでのみジャンプ導線を出す（1 件だけならスクロール不要）。
    final showJump = (threadFuture.asData?.value.length ?? 0) > 1;
    final selected = _selectedPost;
    final menuAdapter = ref.watch(currentAdapterProvider);

    return ScreenMenu(
      label: 'スレッド',
      // コールバックは**名前付きメソッドのテアオフ**で渡す (#835)。その場で
      // 作った無名関数はビルドのたびに別物になり、[MenuActionEntry] の値等価が
      // 崩れてメニューバー全体が作り直される。
      entries: [
        ...buildThreadMenuEntries(
          showJump: showJump,
          onJumpToTop: _jumpToTop,
          onJumpToBottom: _jumpToBottom,
          onReload: _reload,
        ),
        const MenuGroupSeparator(),
        // 選択中の投稿への操作 (#943)。未選択なら全項目が無効で並ぶ。
        //
        // ⚠ **スレッド自体の操作と同じ階層に並べない** (#980)。操作対象は
        // スレッドではなく「いま ↑ ↓ で指している投稿」なので、1 段下げないと
        // 何に対する操作なのかが読み取れない（実際に「出し方がわからない」
        // 状態になった）。見出しの「投稿」は [postLabelProvider] 由来で、
        // モロヘイヤが名乗れば「現在のキュア！」等になる。
        MenuSubmenuEntry(
          label: '現在の${ref.watch(postLabelProvider)}',
          children: buildPostActionMenuEntries(
            boostLabel: ref.watch(reblogLabelProvider),
            bookmarkLabel: ref.watch(bookmarkLabelProvider),
            // 概念の有無は**選択ではなくアダプタ**で決まる (#980)。read でなく
            // watch なのは、アカウント切り替えで項目の有無が変わるため。
            supportsFavorite: menuAdapter is FavoriteSupport,
            supportsBookmark: menuAdapter is BookmarkSupport,
            availability: selected == null
                ? null
                : PostActionAvailability.of(ref, selected),
            onReply: _replyToSelected,
            onQuote: _quoteSelected,
            onBoost: _boostSelected,
            onUnboost: _unboostSelected,
            onFavorite: _favoriteSelected,
            onBookmark: _bookmarkSelected,
          ),
        ),
      ],
      child: _buildScaffold(context, threadFuture, showJump: showJump),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    AsyncValue<List<Post>> threadFuture, {
    required bool showJump,
  }) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('スレッド'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _buildBody(context, ref, threadFuture, showJump: showJump),
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
    AsyncValue<List<Post>> threadFuture, {
    required bool showJump,
  }) {
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
          // ジャンプ FAB が出ているときだけ、その高さぶんスクロール範囲を
          // 伸ばす (#1059)。出ていないときに足すと下端に無駄な余白が残る。
          padding: showJump
              ? const EdgeInsets.only(bottom: _jumpFabReservedHeight)
              : null,
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
        return RetryErrorView(
          message: 'スレッドの読み込みに失敗しました\n${summarizeOpError(error)}',
          isRetrying: threadFuture.isLoading,
          onRetry: () => ref.invalidate(_threadProvider(post.id)),
        );
      },
    );

    // スレッドには入力欄が無いので、本体をそのまま包んで ↑ ↓ を受ける (#849)。
    body = wrapKeyboardListNavigation(child: body);

    // ⚠ **背景より内側**に置く (#1037)。外に出すと背景がナビゲーションバーの
    // 手前で切れて、下端だけ地の色が出る。スレッドは下端に何も置いていないので、
    // ここが無いと最後の投稿がナビゲーションバーのボタンに潜り込む。
    body = BottomSafeArea(child: body);

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

/// スレッド画面がデスクトップメニューへ出す項目 (#912 / #835)。
///
/// **画面にある操作だけを載せる。** 先頭へ / 末尾へ は 2 つの FAB と同じ条件
/// ([showJump]) で有効・無効を切り替え、スレッドが 1 件のときは押せないように
/// する。「使えない操作をメニューにだけ見せない」ため。再読み込みはこれまで
/// エラー時の「再試行」からしか辿れなかったので、成功時にも使えるよう置く。
///
/// リプライ / ブースト / お気に入り等の**投稿単位の操作は載せていない**。実体が
/// `PostTile` 内のアクションシート（長押し）にあり、外から開く口が無いため。
/// 開けるようにするのは単独で扱う（#912 のコメント参照）。
///
/// コールバックを引数で受けるのは、画面全体を pump せずに項目の出し分けを
/// 試験できるようにするため（出し分けの条件が `showJump` 1 つで表せるので
/// 切り出せる。基準は `desktop_menu_model.dart` の「画面メニュー貢献のテストの
/// 流儀」#960）。
@visibleForTesting
List<MenuEntry> buildThreadMenuEntries({
  required bool showJump,
  required VoidCallback onJumpToTop,
  required VoidCallback onJumpToBottom,
  required VoidCallback onReload,
}) => [
  MenuActionEntry(
    label: '先頭へ',
    icon: Icons.keyboard_arrow_up,
    onSelected: showJump ? onJumpToTop : null,
  ),
  MenuActionEntry(
    label: '末尾へ',
    icon: Icons.keyboard_arrow_down,
    onSelected: showJump ? onJumpToBottom : null,
  ),
  const MenuGroupSeparator(),
  MenuActionEntry(label: '再読み込み', icon: Icons.refresh, onSelected: onReload),
];

final _threadProvider = FutureProvider.autoDispose.family<List<Post>, String>((
  ref,
  postId,
) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null) return [];
  final thread = await adapter.getThread(postId);
  return ref.read(isCatEnricherProvider).enrichPosts(thread);
});
