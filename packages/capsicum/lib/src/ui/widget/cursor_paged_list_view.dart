import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../util/exception_scrub.dart';
import '../util/op_error.dart';
import 'retry_error_view.dart';

/// 1 ページぶんの取得。`nextCursor` が null なら打ち止め。
typedef CursorPageFetcher<T> =
    Future<({List<T> items, String? nextCursor})> Function(String? cursor);

/// 取得した 1 ページを加工してから並べる（isCat の補完など）。
///
/// ⚠ **`ref` は呼ばれた時点のものを渡す。**呼び出し側が build 時の `ref` を
/// クロージャに閉じ込めると、await をまたいだあとに dispose 済みの `ref` を
/// 読む形（#1064）になりやすい。ここは `mounted` を確かめた直後に呼ぶので、
/// 渡された `ref` は生きている。
typedef CursorPageEnricher<T> =
    Future<List<T>> Function(WidgetRef ref, List<T> items);

/// カーソルページングの一覧 (#1083-A)。
///
/// ## なぜ集約したか
///
/// ⚠⚠ **同じ骨格が 4 本手書きされていた** — `UserListView` /
/// `PostListScreen` / `FollowedHashtagsScreen`（+ `UserListView` を包む
/// `ModerationListScreen` / `FollowRequestsScreen`）。`diff -w` で見ると
/// `post_list_screen` と `followed_hashtags_screen` は **fetcher をコールバックで
/// 受けるかインライン展開するかを除いて完全に同型**で、`UserListView` の差分も
/// `enrichUsers` の 1 段だけだった。
///
/// ⚠ **汎用化の意図は既にあったのに適用漏れだった。**同じリリースで
/// `PostListScreen` という汎用画面を作りながら、その 2 コミット前の
/// `FollowedHashtagsScreen` が同じ骨格を手書きしている。
///
/// ⚠⚠ **既に揺れが発生していた**（理由の記載なし）:
///
/// | | プリフェッチ閾値 | ページサイズ |
/// | --- | --- | --- |
/// | `post_list_screen` | 600 | fetcher 側 |
/// | `user_list_screen` | 600 | fetcher 側 |
/// | `followed_hashtags_screen` | **400** | **40（画面が持つ）** |
///
/// → **閾値は 600 に揃え**（多数派・理由の記載があるのもこちら）、**ページサイズは
/// fetcher 側に閉じ込める**（`limit` はサーバーの都合なので、渡す側が知っている）。
///
/// ## ⚠ ここに集めた「レビューで積み上がった振る舞い」を落とさないこと
///
/// 4 本それぞれに、別々のレビューで足された守りが入っていた。**集約は、その
/// どれか 1 つでも落とすと退行になる。**
///
/// 1. **「0 件」と「引けない」を混ぜない**（#1041 と同じ趣旨）。取得に失敗した
///    ときに「ブロック中のユーザーはいません」「フォロー中のタグはありません」と
///    出すと、**アカウントの状態について誤った事実を断言する**。ブロックが消えたと
///    誤解して再ブロックしに行く、といった実害が出る
/// 2. **世代カウンタ**（#1083-B / `4692b067`）。引っ張って更新と追加読み込みが
///    交差すると、遅れて着いた `_loadMore` が**新しい 1 ページ目に古い 2 ページ目を
///    連結**し、カーソルも巻き戻る。⚠ `_load` は `_loadingMore` も落とす
/// 3. **継続の判定は件数ではなく `nextCursor` の有無**。サーバーはフィルタで件数を
///    減らしたうえで next リンクを返すことがある
/// 4. **引っ張って更新で `_loading` を立てない**。立てると三項の分岐が変わって
///    `RefreshIndicator` ごとアンマウントされ、**引っぱったスピナーが即座に消える**
class CursorPagedListView<T> extends ConsumerStatefulWidget {
  const CursorPagedListView({
    super.key,
    required this.fetcher,
    required this.itemBuilder,
    required this.emptyMessage,
    required this.debugLabel,
    this.enrich,
  });

  final CursorPageFetcher<T> fetcher;
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// 一覧が空のときの文言。⚠ **失敗時には出さない**（上の 1）。
  final String emptyMessage;

  /// `debugLogException` に載せる識別子（`UserListView` 等）。
  final String debugLabel;

  /// 取得したページの加工。省略時は素通し。
  final CursorPageEnricher<T>? enrich;

  @override
  ConsumerState<CursorPagedListView<T>> createState() =>
      _CursorPagedListViewState<T>();
}

class _CursorPagedListViewState<T>
    extends ConsumerState<CursorPagedListView<T>> {
  /// 末尾から何 px 手前で次のページを取りに行くか。
  ///
  /// ⚠ **画面ごとに変えない (#1083-A)。**`followed_hashtags_screen` だけ 400
  /// だったが、理由の記載が無かった。**揺れは意図ではなく写し間違い**として
  /// 多数派の 600 に揃えた。変えるなら**ここを 1 箇所直し、理由を書く**。
  static const _prefetchThreshold = 600.0;

  final _scrollController = ScrollController();
  List<T> _items = [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  /// 初回取得の失敗。⚠ **「0 件」と描き分けるために要る**（クラス doc の 1）。
  Object? _error;

  /// 取得の世代（クラス doc の 2）。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - _prefetchThreshold) {
      _loadMore();
    }
  }

  Future<List<T>> _enrich(List<T> items) async {
    final enrich = widget.enrich;
    if (enrich == null) return items;
    return enrich(ref, items);
  }

  /// 先頭から取り直す。`RefreshIndicator` と再試行ボタンの両方から呼ぶ。
  Future<void> load() async {
    final generation = ++_generation;
    try {
      final result = await widget.fetcher(null);
      if (!mounted || generation != _generation) return;
      final items = await _enrich(result.items);
      if (!mounted || generation != _generation) return;
      setState(() {
        // ⚠ in-flight の追加読み込みが無効になったことを UI に反映する。
        _loadingMore = false;
        _items = items;
        _nextCursor = result.nextCursor;
        _loading = false;
        _error = null;
        _hasMore = result.nextCursor != null;
      });
    } catch (e) {
      debugLogException('${widget.debugLabel} load error', e);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _items.isEmpty) return;
    // 着地時に load が走り直していたら、この結果は古いページなので捨てる。
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final result = await widget.fetcher(_nextCursor);
      if (!mounted || generation != _generation) return;
      final items = await _enrich(result.items);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = [..._items, ...items];
        _nextCursor = result.nextCursor;
        _loadingMore = false;
        _hasMore = result.nextCursor != null;
      });
    } catch (e) {
      debugLogException('${widget.debugLabel} loadMore error', e);
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    // ⚠ **失敗を「0 件」と描き分ける**（クラス doc の 1）。
    final error = _error;
    if (error != null) {
      return RetryErrorView(
        message: '読み込みに失敗しました\n${summarizeOpError(error)}',
        onRetry: () {
          setState(() {
            _loading = true;
            _error = null;
          });
          load();
        },
      );
    }

    if (_items.isEmpty) return Center(child: Text(widget.emptyMessage));

    return RefreshIndicator(
      // ⚠ **`_loading` を立てない**（クラス doc の 4）。
      onRefresh: load,
      child: ListView.separated(
        controller: _scrollController,
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return widget.itemBuilder(context, _items[index]);
        },
      ),
    );
  }
}
