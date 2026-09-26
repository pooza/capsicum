import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/deck_provider.dart';

/// [columnId] のカラムに枠が出ているかを指すためのキー。
///
/// ⚠ 枠は色と太さで見せるものなので、**出ているかを装飾から読もうとすると
/// 検査が壊れやすい**（テーマの色・アニメーション中の値）。目印を 1 つ置いて、
/// 「出ているか」だけを見る。
Key deckFocusRingKey(String columnId) => ValueKey('deck-focus-ring-$columnId');

/// フォーカス中のカラムを枠で見せ、押されたらフォーカスを移す (#1172・
/// `docs/deck-ui-plan.md` 決定済み事項 10)。
///
/// ⚠ **見出しの濃淡や印では表さない。**見出しの色はサーバーごとにばらばらなので
/// （#1152）、組み合わせ次第で見分けが付かなくなる。
///
/// ⚠⚠ **枠は重ねて描き、カラムの幅を変えない。**`Border` を子の外側に足すと
/// 中身が 2px ずつ狭くなり、投稿タイルが読める下限（375px・未決事項 8）の計算が
/// 狂う。
///
/// ⚠⚠ **スクロールではフォーカスを移さない。**ホイールやトラックパッドで読むだけの
/// ことが多く、読んでいたカラムのアカウントで ⌘N が開いてしまう。`onPointerDown`
/// だけを見るのは、ポインタスクロールが `PointerScrollEvent`（signal）として届き
/// ここに来ないため。
class DeckColumnFocusRing extends ConsumerStatefulWidget {
  const DeckColumnFocusRing({
    super.key,
    required this.columnId,
    required this.showRing,
    required this.child,
  });

  final String columnId;

  /// 枠を出すか。**カラムが 1 本しかないときは出さない**（決定済み事項 10）。
  final bool showRing;

  final Widget child;

  @override
  ConsumerState<DeckColumnFocusRing> createState() =>
      _DeckColumnFocusRingState();
}

class _DeckColumnFocusRingState extends ConsumerState<DeckColumnFocusRing>
    with SingleTickerProviderStateMixin {
  /// 点滅 1 回ぶん。0 → 1 → 0 の三角波で描く。
  ///
  /// ⚠⚠ **`late final` の遅延初期化にしてはいけない。**一度も点滅しないまま
  /// 閉じると、`dispose` の `_blink.dispose()` が**そこで初めて**controller を
  /// 作る。`vsync: this` は `TickerMode` を祖先から引くので、**既に deactivate
  /// された element で祖先を探して落ちる**（「Looking up a deactivated widget's
  /// ancestor is unsafe」）。カラムは点滅せずに閉じるのが普通なので、ほぼ毎回踏む。
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ⚠⚠ **点滅は `ref.listen` で起こす。**`build` の中で
    // `AnimationController.forward` を呼ぶと、その通知が同じフレームの再構築を
    // 要求して落ちる（「setState() or markNeedsBuild() called during build」）。
    // ⚠ 画面を開いた最初の構築では鳴らない（差分が来ないため）。それが正しい —
    // 点滅は「今このカラムが足された」の合図で、開き直しは合図ではない。
    ref.listen<DeckFocus>(deckFocusProvider, (previous, next) {
      if (next.columnId != widget.columnId) return;
      if (previous != null && next.blinkToken == previous.blinkToken) return;
      _blink.forward(from: 0);
    });
    final focus = ref.watch(deckFocusProvider);
    final focused = focus.columnId == widget.columnId;

    final accent = Theme.of(context).colorScheme.primary;
    return Listener(
      // ⚠ 消費しない。カラムの中のタップ・スクロールはそのまま通す。
      onPointerDown: (_) =>
          ref.read(deckFocusProvider.notifier).focus(widget.columnId),
      child: Stack(
        children: [
          widget.child,
          if (widget.showRing && focused)
            Positioned.fill(
              // ⚠ 枠が出ているかを検査から指せるようにする（`deck_focus_ring_test`）。
              key: deckFocusRingKey(widget.columnId),
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _blink,
                  builder: (context, _) {
                    // 三角波（0 → 1 → 0）。止まっているときは 0 なので、常時の枠は
                    // 下の 2px がそのまま出る。
                    final t = _blink.value;
                    final flash = 1 - (t * 2 - 1).abs();
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: accent.withValues(alpha: 0.85 + 0.15 * flash),
                          width: 2 + 2 * flash,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
