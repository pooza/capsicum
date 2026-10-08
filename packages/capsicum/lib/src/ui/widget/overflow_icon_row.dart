import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// [OverflowIconRow] に並べる 1 つ。
class OverflowIconAction {
  const OverflowIconAction({
    required this.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  /// 検査から指すための目印。⚠ 重複させない（畳んだ側のメニュー項目にも使う）。
  final String key;

  final Widget icon;

  /// アイコンの説明。**畳まれたときはメニューの行の文字**になるので、
  /// ⚠ 「メディアを添付」のように**単体で意味が通る**言葉にすること。
  final String tooltip;

  /// null なら押せない（送信中など）。⚠ 畳んだ側でも無効になる。
  final VoidCallback? onPressed;

  /// いま効いているか（閲覧注意が ON・アンケートを開いている 等）。
  ///
  /// ⚠⚠ **畳まれると「効いている」が見えなくなる**ので、[OverflowIconRow] は
  /// 畳んだ中に active があるとき「…」に印を付ける。
  final bool active;
}

/// 幅に入るぶんだけアイコンを並べ、あふれたぶんを「…」メニューへ畳む (#1167)。
///
/// ⚠⚠ **横スクロールをやめるための部品。**投稿画面の下のツールバーは 1 行の横
/// スクロールだったが、**デスクトップでは横スクロールに気付きにくく操作もしにくい**
/// （マウスのホイールは縦にしか回らず、ドラッグでもスクロールしない）ので、
/// はみ出た分は実質的に届かない場所になっていた。
///
/// ⚠ **1 つの幅を固定する。**[itemExtent] を決めて `SizedBox` で固定し、
/// `IconButtonTheme` でタップ枠もそこへ詰める。**幅が可変だと「何個入るか」の
/// 算術が嘘になる**（入ると思って並べてから overflow する）。
///
/// ⚠ 並びは変えない。見えるのは先頭から順で、あふれたぶんはメニューで同じ順。
/// **効いているものを前へ繰り上げたりしない**（押すたびにアイコンが動くと狙えない）。
class OverflowIconRow extends StatelessWidget {
  const OverflowIconRow({
    super.key,
    required this.actions,
    this.itemExtent = 40,
  });

  final List<OverflowIconAction> actions;

  /// 1 つに割り当てる幅。⚠ タップ枠もここへ詰めるので、**40 より小さくしない**
  /// （指で押せる下限）。
  final double itemExtent;

  /// [width] に何個まで見せるか。あふれるなら「…」のぶんを 1 つ取っておく。
  @visibleForTesting
  static int visibleCountFor({
    required double width,
    required int total,
    required double itemExtent,
  }) {
    if (total == 0) return 0;
    final fits = (width / itemExtent).floor();
    if (fits >= total) return total;
    // ⚠ 「…」の場所を取ってから数える。取らないと、最後の 1 つと「…」が並んで
    // またあふれる。⚠ 負にしない（幅が itemExtent 未満のときは 0 個＝全部畳む）。
    final withMenu = fits - 1;
    return withMenu < 0 ? 0 : withMenu;
  }

  @override
  Widget build(BuildContext context) {
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: Size(itemExtent, itemExtent),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final visibleCount = visibleCountFor(
            width: constraints.maxWidth,
            total: actions.length,
            itemExtent: itemExtent,
          );
          final visible = actions.take(visibleCount).toList();
          final hidden = actions.skip(visibleCount).toList();
          return Row(
            children: [
              for (final action in visible)
                SizedBox(
                  width: itemExtent,
                  child: IconButton(
                    key: ValueKey('compose-action-${action.key}'),
                    onPressed: action.onPressed,
                    icon: action.icon,
                    tooltip: action.tooltip,
                  ),
                ),
              if (hidden.isNotEmpty)
                SizedBox(
                  width: itemExtent,
                  child: _OverflowMenu(hidden: hidden),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// アイコン列を横スクロールで並べる (#1167・2026-09-30 pooza 決定の A+C)。
///
/// ## ⚠⚠ 「横スクロールをやめた」を部分的に覆している
///
/// #1167 が横スクロールを捨てたのは、**デスクトップでは気付けず操作もできない**
/// から（ホイールは縦にしか回らず、既定の `ScrollBehavior` はマウスでのドラッグを
/// 許さない）。⚠ **機構そのものが悪かったのではなく、届かないことが悪かった。**
///
/// [OverflowIconRow]（畳む）を狭い幅へ当てたところ、iPhone 13 mini では**設定が
/// 幅の 8 割を占めてアイコンが 1 つも見えなくなった**（2026-09-30 実測）。畳む形は
/// 幅が要るので、**いちばん狭いところでは成り立たない**。
///
/// そこでこの部品は、横スクロールを**届く形にして**戻す:
///
/// | 元の不満 | ここでの手当て |
/// | --- | --- |
/// | 気付けない | ⚠ **スクロールバーを常時表示**（`thumbVisibility: true`） |
/// | マウスで操作できない | ⚠ **ドラッグできる入力にマウス / トラックパッドを足す** |
/// | 送信時の設定が流れて届かない | ⚠⚠ **設定はここへ入れない**（引数が [OverflowIconAction] だけなので**型として入らない**） |
///
/// ⚠ **効いている設定が流れて見えなくなる心配は無い。**閲覧注意は本文欄の上に
/// 入力欄が出るし、アンケートは編集欄、予約はチップ、センシティブは添付のサムネに
/// 出る。**アイコンは入口であって、効いていることの表示ではない。**
///
/// ⚠ スクロールバーは子の上に描かれるので**高さを取らない**（1 段のまま）。
class ScrollingIconRow extends StatelessWidget {
  const ScrollingIconRow({
    super.key,
    required this.actions,
    required this.controller,
    this.itemExtent = 40,
  });

  final List<OverflowIconAction> actions;

  /// ⚠ [Scrollbar] と [SingleChildScrollView] で**同じものを共有する**。別々だと
  /// 「スクロールバーが動かない」ではなく **assert で落ちる**。
  final ScrollController controller;

  /// 1 つに割り当てる幅。⚠ [OverflowIconRow] と揃える（畳む形と流す形で
  /// アイコンの大きさが変わらないように）。
  final double itemExtent;

  @override
  Widget build(BuildContext context) {
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: Size(itemExtent, itemExtent),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
      child: ScrollConfiguration(
        behavior: const _DragAnywhereScrollBehavior(),
        child: Scrollbar(
          controller: controller,
          // ⚠⚠ **常時表示。**「気付けない」が元の不満なので、触るまで出ない
          // スクロールバーでは直したことにならない。
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final action in actions)
                  SizedBox(
                    width: itemExtent,
                    child: IconButton(
                      key: ValueKey('compose-action-${action.key}'),
                      onPressed: action.onPressed,
                      icon: action.icon,
                      tooltip: action.tooltip,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// マウス / トラックパッドでもドラッグしてスクロールできるようにする。
///
/// ⚠⚠ **既定の `ScrollBehavior` は `PointerDeviceKind.mouse` を外している。**
/// これが「デスクトップではドラッグでもスクロールしない」の正体で、#1167 が
/// 横スクロールを捨てる理由になっていた。⚠ **外していた理由は「マウスなら
/// ホイールがあるから」**だが、**ホイールは縦にしか回らない**ので横方向では
/// 代わりにならない。
class _DragAnywhereScrollBehavior extends MaterialScrollBehavior {
  const _DragAnywhereScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };
}

/// 畳んだぶんを出すメニュー。
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({required this.hidden});

  final List<OverflowIconAction> hidden;

  @override
  Widget build(BuildContext context) {
    // ⚠⚠ 畳んだ中に効いているものがあれば印を付ける。付けないと「閲覧注意が ON
    // なのに画面のどこにも出ていない」状態になる（`localOnly` の不具合と同型の
    // 「見えないまま効いている」）。
    final anyActive = hidden.any((a) => a.active);
    final accent = Theme.of(context).colorScheme.primary;
    return PopupMenuButton<OverflowIconAction>(
      key: const ValueKey('compose-action-overflow'),
      tooltip: 'ほかの操作',
      // ⚠ 閉じた押し心地を並びのアイコンと同じにする（枠は SizedBox が決める）。
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_horiz, color: anyActive ? accent : null),
      onSelected: (action) => action.onPressed?.call(),
      itemBuilder: (context) => [
        for (final action in hidden)
          PopupMenuItem(
            key: ValueKey('compose-overflow-${action.key}'),
            value: action,
            // ⚠ 押せないものはメニューでも押せない。
            enabled: action.onPressed != null,
            child: Row(
              children: [
                IconTheme.merge(
                  data: IconThemeData(
                    size: 20,
                    color: action.active ? accent : null,
                  ),
                  child: action.icon,
                ),
                const SizedBox(width: 12),
                Text(
                  action.tooltip,
                  style: action.active ? TextStyle(color: accent) : null,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
