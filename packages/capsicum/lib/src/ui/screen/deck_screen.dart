import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../model/account_key.dart';
import '../../model/deck_column.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../util/deck_layout.dart';
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

  @override
  void dispose() {
    for (final container in _containers.values) {
      container.dispose();
    }
    super.dispose();
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
    final child =
        widget.columnBuilder?.call(column) ?? DeckColumnView(column: column);
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

    return Scaffold(
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
                  return SingleChildScrollView(
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
  }
}
