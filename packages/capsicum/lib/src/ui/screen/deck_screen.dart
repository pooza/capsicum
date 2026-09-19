import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../model/account_key.dart';
import '../../model/deck_column.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../util/deck_layout.dart';
import '../util/deck_navigation.dart';
import '../util/mouse_drag_scroll_behavior.dart';
import '../util/provider_scope_carrier.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/deck_column_view.dart';
import '../widget/deck_columns_sheet.dart';

/// デッキ画面 (#1092)。カラムを横に並べる。
///
/// ⚠ **別画面として足し、タブ UI（HomeScreen）には手を入れない**
/// （`docs/deck-ui-plan.md` 決定済み事項 8・2026-09-17 pooza 決定）。
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

  @override
  void dispose() {
    _scrollController.dispose();
    for (final container in _containers.values) {
      container.dispose();
    }
    super.dispose();
  }

  /// カラムから開いた投稿・プロフィール等を、元のカラムの右隣に足す (#1148・
  /// 決定済み事項 9)。アカウントは元のカラムのものを引き継ぐ。
  Future<void> _openColumn(DeckColumn from, TabType tab, Object? seed) async {
    final added = await ref
        .read(deckColumnsProvider.notifier)
        .insertAfter(from.id, from.account, tab, seed: seed);
    if (!mounted) return;
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
        overrides: [currentAccountProvider.overrideWithValue(account)],
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
        title: const Text('デッキ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.view_column_outlined),
            tooltip: 'カラム編集',
            onPressed: () => showDeckColumnsSheet(context),
          ),
        ],
      ),
      // 各カラムの最後の投稿がナビゲーションバーに潜らないよう、下端の inset を
      // 画面でまとめて吸う (#1037 / #1062)。
      body: BottomSafeArea(
        child: columns.isEmpty
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
                            child: child,
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
