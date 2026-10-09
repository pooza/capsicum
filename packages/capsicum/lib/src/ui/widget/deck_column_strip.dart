import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/deck_column.dart';
import '../../provider/server_config_provider.dart';
import '../util/deck_tabs.dart';

/// 帯の高さ。
const double kDeckColumnStripHeight = 48;

/// 帯の 1 コマの幅。
const double kDeckColumnStripItemWidth = 52;

/// 見たいカラムへ 1 回で飛べる帯 (#1241・2026-10-09 pooza)。
///
/// 狭幅のデッキはカラムが 1 本ずつしか見えないので、N 本目へ行くには N-1 回
/// スワイプするか、カラム編集のシートを開いて選ぶ（2 タップ・#1229）しか
/// なかった。列の全体を常に見せ、押した 1 回で飛べるようにする。
///
/// - コマはカラムの種別のアイコン。背景は**そのカラムのアカウントのサーバーの色**
///   （カラムの見出しと同じ色・#1152）
/// - いま見ているカラムには印（下線）を付け、ほかは少し沈める
/// - 列が画面より長いときは横へ流れ、いま見ているカラムが見える位置へ寄る
///
/// ⚠ **色だけで区別しない。**同じサーバーの別アカウントは同じ色になるので、
/// 並び順と印が位置を、ツールチップがアカウントを伝える。
///
/// ⚠ 出すかどうか（狭幅のときだけ）は呼ぶ側が決める。
class DeckColumnStrip extends ConsumerStatefulWidget {
  const DeckColumnStrip({
    super.key,
    required this.columns,
    required this.focusedId,
    required this.onSelected,
  });

  final List<DeckColumn> columns;

  /// いま見ているカラムの [DeckColumn.id]。
  final String? focusedId;

  /// コマを押した。引数は [DeckColumn.id]。
  final void Function(String id) onSelected;

  @override
  ConsumerState<DeckColumnStrip> createState() => _DeckColumnStripState();
}

class _DeckColumnStripState extends ConsumerState<DeckColumnStrip> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocused(false));
  }

  @override
  void didUpdateWidget(DeckColumnStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusedId != widget.focusedId ||
        oldWidget.columns.length != widget.columns.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocused(true));
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// いま見ているカラムのコマを、帯の中で見える位置（できれば中央）へ寄せる。
  void _revealFocused(bool animate) {
    if (!mounted || !_scrollController.hasClients) return;
    final index = widget.columns.indexWhere((c) => c.id == widget.focusedId);
    if (index < 0) return;
    final position = _scrollController.position;
    final target =
        (index * kDeckColumnStripItemWidth -
                (position.viewportDimension - kDeckColumnStripItemWidth) / 2)
            .clamp(0.0, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) return;
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hostColors = ref.watch(hostThemeColorProvider);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SizedBox(
        height: kDeckColumnStripHeight,
        child: ListView.builder(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          itemExtent: kDeckColumnStripItemWidth,
          itemCount: widget.columns.length,
          itemBuilder: (context, index) {
            final column = widget.columns[index];
            final focused = column.id == widget.focusedId;
            // ⚠ アカウントをまたぐカラムには、特定のアカウントの色を付けない
            // (#1259)。
            final spansAccounts = column.tab.spansAccounts;
            final background = spansAccounts
                ? theme.colorScheme.surfaceContainerHighest
                : resolveHostColor(hostColors, column.account.host);
            final foreground = spansAccounts
                ? theme.colorScheme.onSurface
                : foregroundOnHostColor(background);
            final account = column.account;
            return Tooltip(
              message: spansAccounts
                  ? 'カラム ${index + 1}（すべてのアカウント）'
                  : 'カラム ${index + 1}（@${account.username}@${account.host}）',
              child: Semantics(
                selected: focused,
                button: true,
                child: InkWell(
                  onTap: () => widget.onSelected(column.id),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 3),
                    child: Column(
                      children: [
                        Expanded(
                          child: Opacity(
                            // いま見ているカラム以外は少し沈める。
                            opacity: focused ? 1 : 0.55,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: background,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: Icon(
                                  deckTabIcon(column.tab),
                                  size: 20,
                                  color: foreground,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        // いま見ているカラムの印。⚠ 色の濃淡だけにしない
                        // （サーバーの色しだいで見分けが付かなくなる）。
                        Container(
                          height: 3,
                          width: 24,
                          decoration: BoxDecoration(
                            color: focused
                                ? theme.colorScheme.primary
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
