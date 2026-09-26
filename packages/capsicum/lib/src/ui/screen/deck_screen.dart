import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../model/account.dart';
import '../../model/account_key.dart';
import '../../model/deck_column.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/deck_provider.dart';
import '../../provider/preferences_provider.dart';
import '../util/deck_compose.dart';
import '../util/deck_layout.dart';
import '../util/deck_navigation.dart';
import '../util/mouse_drag_scroll_behavior.dart';
import '../util/provider_scope_carrier.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/deck_column_focus.dart';
import '../widget/deck_column_view.dart';
import '../widget/deck_columns_sheet.dart';
import '../widget/livecure_filter_button.dart';
import '../widget/simple_post_bar.dart';
import '../widget/user_avatar.dart';

/// デッキ画面 (#1092)。カラムを横に並べる。
///
/// ⚠ **別画面として足し、タブ UI（HomeScreen）には手を入れない**
/// （`docs/deck-ui-plan.md` 決定済み事項 8・2026-09-17 pooza 決定）。⚠ 例外は
/// **切り替えのアイコン 1 点だけ**（#1153・2026-09-22）。タブ UI とデッキの AppBar に
/// 対で置き、見た目は切り替えスイッチ・実体は画面遷移のまま。
///
/// ⚠ **常駐ドロワーを持たない。**900px 以上で 304px を常駐させると、窓を 1px
/// 広げただけでカラムが 2 本から 1 本に落ちる（未決事項 8）。
///
/// ⚠⚠ **列にあるカラムは全部生かす**（可視かどうかではない・決定済み事項 5-3）。
/// `ListView` のように画面外の子を捨てるコンテナを使うと、**横に 1 つスクロールして
/// 戻っただけで TL が真っ白から取り直しになり、スクロール位置も消える。**`Row` で
/// 全カラムを常に組み立てるのはそのため。⚠ カラム数が増えるほどメモリに効くが、
/// **上限を設けるかは実機で測ってから**（先回りで入れない）。
///
/// ## カラムごとのアカウント (#1096)
///
/// カラムの中身は `currentAccountProvider` を読む既存の部品（`PostTile` 等）で
/// できているので、**カラムの位置でそれをカラムのアカウントに上書きする**（案 S・
/// 設計書 1-7）。⚠⚠ **上書きの単位はカラムではなくアカウント**（未決事項 10）:
///
/// - **アカウントごとに `ProviderContainer` を 1 つ作り、そのアカウントのカラム全部で
///   共有する。**カラムごとに作ると、同じアカウントの重複カラムが TL を共有しない
///   うえ、**同じ購読キーでアダプタの購読がぶつかって先のカラムのライブが止まる**
/// - ⚠ **現在のアカウントのカラムはルートのまま。**デッキは HomeScreen の上に push
///   されるので、HomeScreen が同じ TL を watch し続けている。別コンテナにすると
///   同じ理由でぶつかる
class DeckScreen extends ConsumerStatefulWidget {
  const DeckScreen({super.key, this.columnBuilder});

  /// カラムの中身を差し替える口。**テスト用**（`PostTile` の依存一式を用意せずに、
  /// コンテナの振る舞いだけを見るため）。null なら [DeckColumnView]。
  @visibleForTesting
  final Widget Function(DeckColumn column)? columnBuilder;

  @override
  ConsumerState<DeckScreen> createState() => _DeckScreenState();
}

class _DeckScreenState extends ConsumerState<DeckScreen> {
  /// アカウント → そのアカウントのカラムが共有するコンテナ。
  final Map<AccountKey, ProviderContainer> _containers = {};

  /// コンテナへ最後に渡した `Account`。インスタンスが変わったら上書きを更新する。
  final Map<AccountKey, Account> _containerAccounts = {};

  final _scrollController = ScrollController();

  /// 直近の割り付け。足したカラムを見える位置まで送るのに使う。
  DeckLayout? _layout;

  /// ルートのコンテナ。⚠ [dispose] の時点では `ref` が使えないので、開いている
  /// 間の数 ([mountedDeckCountProvider]) を戻す口を initState で掴んでおく。
  late final ProviderContainer _root;

  /// 開いている数を [delta] だけ動かす (#1099)。
  ///
  /// ⚠⚠ **フレームの後で行う。**initState / dispose の最中に provider を書き換え
  /// ると Riverpod が assert で落とす（「Tried to modify a provider while the
  /// widget tree was building」）。
  ///
  /// ⚠ **`mounted` で握り潰さない。**開いた直後に閉じた場合でも、増やす側が
  /// 飛んで減らす側だけが走ると数が負に振り切れる。予約の順は保たれるので、
  /// 対称に投げておけば辻褄が合う。
  void _shiftMountedDecks(int delta) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _root.read(mountedDeckCountProvider.notifier).update((n) => n + delta);
      } on StateError {
        // ⚠ 減らす側の予約が、ルートのコンテナごと畳まれた後のフレームで走ること
        // がある（アプリの終了・テストのツリー差し替え）。戻す先そのものが無く
        // なっているので、握って構わない。
      }
    });
  }

  /// 狭幅でのフォーカス追従を、フレームに 1 回へ間引くための予約済みフラグ。
  bool _focusSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    _root = ProviderScope.containerOf(context, listen: false);
    // ⚠ 投稿・ブロックの反映先がカラム列から解決されるようになる (#1099)。
    // 閉じている間に列を読むと、片づいたはずの TL provider を起こしてしまう。
    _shiftMountedDecks(1);
    _scrollController.addListener(_syncFocusToVisibleColumn);
  }

  @override
  void dispose() {
    _shiftMountedDecks(-1);
    _scrollController.removeListener(_syncFocusToVisibleColumn);
    _scrollController.dispose();
    for (final container in _containers.values) {
      container.dispose();
    }
    super.dispose();
  }

  /// 狭幅（1 本ずつしか見えない幅）では、**見えているカラムがフォーカス** (#1172・
  /// 決定済み事項 10)。横に送ると移る。
  ///
  /// ⚠⚠ **フレームの後で書く。**スクロールの通知はレイアウトの途中でも飛ぶので、
  /// その場で provider を書くと依存するウィジェットの再構築をレイアウト中に
  /// 要求してしまう。⚠ フレームに 1 回へ間引くのも同じ理由（1 回のフリックで
  /// 数十回通知が来る）。
  ///
  /// ⚠ **2 本以上見えているときは何もしない。**そこでは「どれを読んでいるか」を
  /// スクロール位置から決められないので、押された場所（[DeckColumnFocusRing]）だけを
  /// 契機にする。
  void _syncFocusToVisibleColumn() {
    if (_focusSyncScheduled) return;
    _focusSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusSyncScheduled = false;
      final layout = _layout;
      if (!mounted || layout == null || layout.visibleColumns != 1) return;
      if (!_scrollController.hasClients) return;
      final columns = ref.read(deckColumnsProvider);
      final index = (_scrollController.position.pixels / layout.columnWidth)
          .round();
      if (index < 0 || index >= columns.length) return;
      ref.read(deckFocusProvider.notifier).focus(columns[index].id);
    });
  }

  /// カラムから開いた投稿・プロフィール等を、元のカラムの右隣に足す (#1148・
  /// 決定済み事項 9)。アカウントは元のカラムのものを引き継ぐ。
  Future<void> _openColumn(DeckColumn from, TabType tab, Object? seed) async {
    final added = await ref
        .read(deckColumnsProvider.notifier)
        .insertAfter(from.id, from.account, tab, seed: seed);
    if (!mounted) return;
    // ⚠ 開いた時点でフォーカスになり、枠を 1 回点滅させる (#1172・決定済み事項 10)。
    // 横送りで列がずれても、どこに出たかを見失わないため。アカウントは元のカラムを
    // 引き継ぐので、⌘N の宛先のアカウントは変わらない。
    ref.read(deckFocusProvider.notifier).focusAndBlink(added.id);
    // ⚠ 足した直後のフレームではまだ Row に居ない。組み上がってから送る。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(added.id));
  }

  /// 中身の画面が「閉じる」とき（コレクションを削除した等）にカラムを外す (#1150)。
  void _closeColumn(DeckColumn column) =>
      ref.read(deckColumnsProvider.notifier).remove(column.id);

  /// [id] のカラムが画面に入るよう横に送る。入っていれば動かさない。
  ///
  /// 送り先はカラム幅の倍数に揃える（スナップの位置から外さない）。
  void _reveal(String id) {
    final layout = _layout;
    if (!mounted || layout == null || !_scrollController.hasClients) return;
    final index = ref.read(deckColumnsProvider).indexWhere((c) => c.id == id);
    if (index < 0) return;
    final position = _scrollController.position;
    final width = layout.columnWidth;
    final first = (position.pixels / width).round();
    final last = first + layout.visibleColumns - 1;
    final double target;
    if (index < first) {
      target = index * width;
    } else if (index > last) {
      target = (index - layout.visibleColumns + 1) * width;
    } else {
      return;
    }
    _scrollController.animateTo(
      target.clamp(0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  ProviderContainer _containerFor(Account account) {
    final key = account.key;
    final existing = _containers[key];
    if (existing == null) {
      _containerAccounts[key] = account;
      return _containers[key] = ProviderContainer(
        parent: ProviderScope.containerOf(context, listen: false),
        overrides: [
          currentAccountProvider.overrideWithValue(account),
          // ⚠ ここが「カラムのスコープ」の目印 (#1099)。投稿・ブロックの反映先を
          // 解決するとき、ルートで選ばれているタブをこのアカウントに当てない。
          inDeckColumnProvider.overrideWithValue(true),
        ],
      );
    }
    if (!identical(_containerAccounts[key], account)) {
      _containerAccounts[key] = account;
      // ⚠ build の最中に上書きを変えると、依存するウィジェットの再構築を build 中に
      // 要求してしまう。フレームの後で差し替える（ルートで `current` の Account が
      // 差し替わったときと同じく、読んでいる provider が作り直される）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _containers[key] != existing) return;
        existing.updateOverrides([
          currentAccountProvider.overrideWithValue(account),
          inDeckColumnProvider.overrideWithValue(true),
        ]);
      });
    }
    return existing;
  }

  /// 列から居なくなったアカウントのコンテナを片づける。
  void _disposeUnused(Set<AccountKey> used) {
    final unused = _containers.keys.where((k) => !used.contains(k)).toList();
    if (unused.isEmpty) return;
    final doomed = [for (final k in unused) _containers.remove(k)!];
    for (final k in unused) {
      _containerAccounts.remove(k);
    }
    // ⚠ このフレームではまだ古いコンテナを読むウィジェットが居るので、後で捨てる。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final container in doomed) {
        container.dispose();
      }
    });
  }

  Widget _column(
    DeckColumn column,
    AccountKey? currentKey,
    List<Account> accounts,
    Set<AccountKey> used,
  ) {
    // ⚠ カラムの中から開く投稿・プロフィール等は、ここで渡す口を通って右隣の
    // カラムになる (#1148)。シートの中にも持ち込まれる（InheritedTheme）。
    final child = DeckColumnScope(
      column: column,
      onOpen: _openColumn,
      onClose: _closeColumn,
      child:
          widget.columnBuilder?.call(column) ?? DeckColumnView(column: column),
    );
    if (column.account == currentKey) return child;
    final account = accounts.where((a) => a.key == column.account).firstOrNull;
    if (account == null) {
      // 索引に居るが未接続・到達不能のアカウント（決定済み事項 5-1）。ログインし直すと
      // `accounts` に入り、そのまま動き出す。
      return DeckColumnUnavailable(column: column);
    }
    used.add(account.key);
    // ⚠ UncontrolledProviderScope だけだと、カラムから開いたシート / ダイアログ /
    // メニューはルートのスコープ（現在のアカウント）で動く (#1149)。
    return carryProviderScope(_containerFor(account), child);
  }

  /// 画面下端の簡易投稿バー（デッキ全体で 1 本・#1172・決定済み事項 10）。
  ///
  /// 宛先は**フォーカス中のカラムのアカウント**で、バーの左端にそのアカウントの
  /// アイコンを出す。⚠ **カラムごとに置く案は採らない**（カラム数ぶん縦を食う・
  /// 375px では入力欄が短すぎる）。
  ///
  /// ⚠⚠ **バーはフォーカス中のカラムのスコープの中で組む。**ルートで組むと
  /// `currentAdapterProvider` が現在のアカウントを指し、**別アカウントのカラムを
  /// 見ながら打った投稿が現在のアカウントから出る**（#1149 と同じ穴）。
  ///
  /// フォーカスが無い / アカウントが未接続なら null（バーを出さない）。
  Widget? _postBar(
    List<DeckColumn> columns,
    AccountKey? currentKey,
    List<Account> accounts,
    Set<AccountKey> used,
  ) {
    final focusedId = ref.watch(deckFocusProvider).columnId;
    final column = columns.where((c) => c.id == focusedId).firstOrNull;
    if (column == null) return null;
    final bar = _DeckPostBar(column: column);
    if (column.account == currentKey) return bar;
    final account = accounts.where((a) => a.key == column.account).firstOrNull;
    if (account == null) return null;
    used.add(account.key);
    return carryProviderScope(_containerFor(account), bar);
  }

  /// [content] の下に [postBar] を置く。バーが無いときは下端の inset を
  /// [BottomSafeArea] で吸う（#1037 / #1062・上の `body` の注記）。
  Widget _withPostBar(Widget? postBar, Widget content) => postBar == null
      ? BottomSafeArea(child: content)
      : Column(
          children: [
            Expanded(child: content),
            postBar,
          ],
        );

  @override
  Widget build(BuildContext context) {
    final columns = ref.watch(deckColumnsProvider);
    final minColumnWidth = ref.watch(deckColumnWidthProvider);
    final currentKey = ref.watch(currentAccountKeyProvider);
    final accounts = ref.watch(accountManagerProvider).accounts;

    final used = <AccountKey>{};
    final columnWidgets = [
      for (final column in columns)
        (column, _column(column, currentKey, accounts, used)),
    ];
    // ⚠ バーもフォーカス中のカラムのコンテナを使うので、`_disposeUnused` より先に
    // 組んで `used` に入れる（そうしないと、そのアカウントのカラムが 1 本も
    // 見えていない状況でコンテナを畳んでしまう）。
    final postBar = _postBar(columns, currentKey, accounts, used);
    _disposeUnused(used);

    // ⚠⚠ デスクトップでは引っ張って更新ができなかった (#1157)。マウスと
    // トラックパッドは既定の dragDevices に入っておらず、2 本指スクロールは
    // ポインタスクロールとして届くので **RefreshIndicator が起動しない**。
    // カラムには引っ張る以外の再読み込みの入口も無いので、実機検証 (#1098) では
    // 「カラムを閉じて足し直す」で代替するしかなかった。
    // ⚠ **設定 (#574) に従う**（2026-09-19 pooza 判断）。既定の OFF では
    // トラックパッド 2 本指スワイプの既存挙動をそのまま維持する。
    final mouseDragEnabled = ref.watch(mouseDragScrollProvider);
    final scaffold = Scaffold(
      appBar: AppBar(
        // ⚠ 戻る（←）は出さない (#1153・2026-09-22 pooza)。タブ UI へ戻るのは
        // 右端の「タブ表示に切り替え」に一本化した（AppBar の切り替えと役割が
        // 重なるため）。
        automaticallyImplyLeading: false,
        title: const Text('デッキ'),
        actions: [
          // ⚠ アイコンが増えたので、タブ UI と同じコンパクト枠に詰める (#1173)。
          // 既定の 48px タップ枠のままだと、狭幅（375px）でタイトルが潰れる。
          IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                minimumSize: const Size(36, 40),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ⚠ ライブ更新の接続インジケータは置かない（決定済み事項 7-2 / 7-3）。
                // カラムごとに購読があるので、画面共通に 1 個置くと「N 本あるうちの
                // どれの状態でもないもの」を出すことになる（#793 の再発）。
                //
                // ⚠ 実況の切り替え (#1173)。フィルタ自体はカラムにも既に効いて
                // いるので入口だけ。**モバイルのデッキには入口が無かった**
                // （デスクトップはメニューバーから切り替えられる）。
                const LivecureFilterButton(),
                IconButton(
                  icon: const Icon(Icons.view_column_outlined),
                  tooltip: 'カラム編集',
                  onPressed: () => showDeckColumnsSheet(context),
                ),
                // タブ表示への切り替え (#1153)。タブ UI の AppBar の「デッキ表示に
                // 切り替え」と対になる。⚠ **`go('/home')` は下に残っている
                // HomeScreen を作り直さない**（go_router が同じページを使い回す・
                // `deck_switch_test` で固定）。HomeScreen が同じ TL を watch し
                // 続ける前提（決定済み事項 8）はこれで崩れない。
                // ⚠ `push('/home')` にすると 2 枚目が積まれて壊れる。
                IconButton(
                  icon: const Icon(Icons.tab_outlined),
                  tooltip: 'タブ表示に切り替え',
                  onPressed: () => context.go('/home'),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ],
      ),
      // 各カラムの最後の投稿がナビゲーションバーに潜らないよう、下端の inset を
      // 画面でまとめて吸う (#1037 / #1062)。⚠ 簡易投稿バーを出しているときは
      // **バーが inset を吸う**（`SimplePostBar` が `padding.bottom` を自分で
      // 足す設計・`bottom_safe_area.dart`）ので、ここでは包まない。包むと
      // バーの上に無駄な余白が入る。
      body: _withPostBar(
        postBar,
        columns.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('カラムがありません'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('カラムを追加'),
                      onPressed: () => showDeckColumnsSheet(context),
                    ),
                  ],
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final layout = computeDeckLayout(
                    availableWidth: constraints.maxWidth,
                    columnCount: columns.length,
                    minColumnWidth: minColumnWidth,
                  );
                  _layout = layout;
                  return SingleChildScrollView(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    physics: DeckSnapScrollPhysics(
                      columnWidth: layout.columnWidth,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (column, child) in columnWidgets)
                          SizedBox(
                            // ⚠ 列内の安定 id をキーにする（決定済み事項 6-2）。
                            // 中身（アカウント + 種別）は重複しうるので使えない。
                            key: ValueKey(column.id),
                            width: layout.columnWidth,
                            height: constraints.maxHeight,
                            // フォーカス中の枠と、押されたときのフォーカス移動
                            // (#1172)。⚠ **枠は 1 本のときは出さない**
                            // （決定済み事項 10）。
                            child: DeckColumnFocusRing(
                              columnId: column.id,
                              showRing: columns.length > 1,
                              child: child,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
    return mouseDragEnabled
        ? ScrollConfiguration(
            behavior: const MouseDragScrollBehavior(),
            child: scaffold,
          )
        : scaffold;
  }
}

/// デッキの簡易投稿バー (#1172)。**フォーカス中のカラムのスコープの中で組む**
/// （`_DeckScreenState._postBar` が包む）ので、ここの `ref` はそのカラムの
/// アカウントを指している。
class _DeckPostBar extends ConsumerWidget {
  const _DeckPostBar({required this.column});

  final DeckColumn column;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adapter = ref.watch(currentAdapterProvider);
    if (!canComposeFromColumn(column.tab, adapter)) {
      // ⚠ 投稿できないカラム（メッセージ・チャンネル非対応）でもバーの代わりに
      // 下端の inset は吸う。誰も吸わないと最後の投稿がナビゲーションバーの
      // ボタンに潜り込む (#1037)。
      return const BottomSafeArea(child: SizedBox.shrink());
    }
    // ⚠ 初期状態は見出しの投稿ボタンと同じ関数から取る (#1172)。別々に書くと、
    // 「バーから送るとタグが付くのにボタンから開くと付かない」の再発になる。
    final extra = deckComposeExtra(ref, column);
    final current = ref.watch(currentAccountProvider);
    final user = current?.key == column.account ? current!.user : null;
    return SimplePostBar(
      // ⚠ フォーカスが移ったら別のバーとして作り直す。同じ State を使い回すと
      // 打ちかけの本文が別のアカウント宛に持ち越される。
      key: ValueKey(column.id),
      channelId: extra['channelId'] as String?,
      channelName: extra['channelName'] as String?,
      hashtags: (extra['hashtags'] as List<String>?) ?? const [],
      // 誰として投稿するかをバー自身に出す（決定済み事項 10）。
      leading: user == null
          ? null
          : UserAvatar(user: user, size: 24, compact: true),
      // ⚠ `onPosted` は渡さない。デッキのカラムへの反映は楽観挿入が担う
      // （`readVisibleTimelines` が列のカラムを宛先に含める・#1099）。ここで
      // `invalidate` すると、そのカラムだけ REST で丸ごと取り直しになる。
    );
  }
}
