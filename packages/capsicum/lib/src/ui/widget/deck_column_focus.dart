import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/deck_provider.dart';

/// [columnId] のカラムに枠が出ているかを指すためのキー。
///
/// ⚠ 枠は色と太さで見せるものなので、**出ているかを装飾から読もうとすると
/// 検査が壊れやすい**（テーマの色・アニメーション中の値）。目印を 1 つ置いて、
/// 「出ているか」だけを見る。
Key deckFocusRingKey(String columnId) => ValueKey('deck-focus-ring-$columnId');

/// 常時の枠を出さない幅で、[columnId] のカラムが点滅している間だけ在る目印。
Key deckFocusBlinkKey(String columnId) =>
    ValueKey('deck-focus-blink-$columnId');

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
/// ⚠⚠ **カラムの中を縦にスクロールしても移す**（#1330・2026-10-22 pooza）。
/// ホイールとトラックパッドの 2 本指は pointer down を伴わないので、
/// `onPointerDown` だけでは**読み進めたカラムにフォーカスが来ず**、前に触った
/// カラムのアカウントで簡易投稿バー・⌘N が動いていた（投稿するアカウントの
/// 取り違え・#1328）。⚠ 以前は「読むだけで ⌘N の宛先が変わる」ことを嫌って
/// 移さなかったが、実際の使い方では**読んでいたカラムに書きたい**ほうだった。
///
/// ⚠ **見るのはカラムの中の `Scrollable` が出す [UserScrollNotification] だけ。**
/// - デッキの横送り（カラムの並びの `Scrollable`）はこの枠の**外**にあるので、
///   通知がここを通らない ＝ 横送りでは移らない
/// - プログラムからのスクロール（新着で位置を保つ等）は利用者の向きを変えないので
///   通知が出ない
/// - ホイールは 1 回ごとに向きが idle → forward / reverse と変わるので毎回届く
///   （`ScrollPositionWithSingleContext.pointerScroll`）
/// - ⚠ 横向きの `Scrollable`（カラムの中のタグの列など）では移さない。移す条件は
///   「縦に読み進めた」で決めた（#1330）
/// - ⚠ 点滅（`focusAndBlink`）はさせない。スクロールのたびに光ると煩い
class DeckColumnFocusRing extends ConsumerStatefulWidget {
  const DeckColumnFocusRing({
    super.key,
    required this.columnId,
    required this.showRing,
    required this.child,
  });

  final String columnId;

  /// **常時の**枠を出すか。**同時に見えているカラムが 1 本のときは出さない**
  /// （決定済み事項 10・#1243）。⚠ 「列に 1 本」ではなく「見えているのが 1 本」で
  /// 決める。
  ///
  /// ⚠⚠ **点滅はこの値に関わらず出す。**点滅は「押した操作が効いた」の合図で、
  /// いま見えているカラムを開き直す操作（通知カラムを見ながら通知を押す・
  /// カラム編集でいま見えているカラムを選ぶ）は、点滅が無いと**何も起きない
  /// ように見える**（2 回目の差分レビュー・2026-10-06）。
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
      child: NotificationListener<UserScrollNotification>(
        // ⚠ 消費しない（false）。上の `RefreshIndicator` 等にもそのまま届ける。
        onNotification: (notification) {
          if (notification.direction != ScrollDirection.idle &&
              notification.metrics.axis == Axis.vertical) {
            ref.read(deckFocusProvider.notifier).focus(widget.columnId);
          }
          return false;
        },
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
                            color: accent.withValues(
                              alpha: 0.85 + 0.15 * flash,
                            ),
                            width: 2 + 2 * flash,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              )
            else if (focused)
              // ⚠ 常時の枠が無い幅では、点滅している間だけ描く（止まれば何も無い）。
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _blink,
                    builder: (context, _) {
                      final t = _blink.value;
                      final flash = 1 - (t * 2 - 1).abs();
                      if (!_blink.isAnimating || flash <= 0) {
                        return const SizedBox.shrink();
                      }
                      return DecoratedBox(
                        key: deckFocusBlinkKey(widget.columnId),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: accent.withValues(alpha: flash),
                            width: 4 * flash,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
