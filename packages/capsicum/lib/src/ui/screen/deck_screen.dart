import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/deck_column.dart';
import '../../provider/preferences_provider.dart';
import '../util/deck_layout.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/deck_column_view.dart';

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
class DeckScreen extends ConsumerWidget {
  const DeckScreen({super.key, this.columnBuilder});

  /// カラムの中身を差し替える口。**テスト用**（`PostTile` の依存一式を用意せずに、
  /// コンテナの振る舞いだけを見るため）。null なら [DeckColumnView]。
  @visibleForTesting
  final Widget Function(DeckColumn column)? columnBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columns = ref.watch(deckColumnsProvider);
    final minColumnWidth = ref.watch(deckColumnWidthProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('デッキ')),
      // 各カラムの最後の投稿がナビゲーションバーに潜らないよう、下端の inset を
      // 画面でまとめて吸う (#1037 / #1062)。
      body: BottomSafeArea(
        child: columns.isEmpty
            ? const Center(child: Text('カラムがありません'))
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
                        for (final column in columns)
                          SizedBox(
                            // ⚠ 列内の安定 id をキーにする（決定済み事項 6-2）。
                            // 中身（アカウント + 種別）は重複しうるので使えない。
                            key: ValueKey(column.id),
                            width: layout.columnWidth,
                            height: constraints.maxHeight,
                            child:
                                columnBuilder?.call(column) ??
                                DeckColumnView(column: column),
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
