import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// AppBar 右上の通知ベル。
///
/// - 単一アカウント: タップで現在アカウントの通知画面（/notifications）
/// - 複数アカウント: タップでまとめ画面（/notifications/all）— #345 で変更
/// - 長押しでポップアップメニューから明示選択も可能
///
/// ⚠ **`home_screen.dart` から切り出してある (#1196)。**ツールチップと長押し
/// メニューの両立は壊れやすく（下の `Tooltip` の置き場所を参照）、**検査を書く
/// ために単体で pump できる必要があった**。兄弟の AppBar 部品
/// （`LivecureFilterButton` / `NotificationFilterButton`）も同じくここに居る。
class NotificationBellButton extends StatelessWidget {
  final bool hasMultipleAccounts;

  const NotificationBellButton({super.key, required this.hasMultipleAccounts});

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      icon: const Icon(Icons.notifications_outlined),
      // 複数アカウント時は長押しメニューを自前で出すため IconButton の
      // tooltip は付けない。built-in tooltip が long-press gesture を
      // 横取りして、外側の GestureDetector.onLongPress が発火しない。
      // ⚠ **その代わり下で Tooltip を手で巻く**（#1196）。
      tooltip: hasMultipleAccounts ? null : '通知',
      onPressed: () => context.push(
        hasMultipleAccounts ? '/notifications/all' : '/notifications',
      ),
    );
    if (!hasMultipleAccounts) return button;
    // ⚠⚠ **効いているのは「`Tooltip` を `GestureDetector` の外側に置くこと」
    // (#1196)。**built-in tooltip は `IconButton` の中、つまり
    // `GestureDetector` の**内側**に入るので、gesture arena で内側が勝って
    // 長押しを奪う。外側に置けば内側のメニューが勝つ（検査で実測）。
    //
    // ⚠ `triggerMode: manual` は**その上の保険**。既定の `longPress` でも
    // いまは通るが、両者の `LongPressGestureRecognizer` が同じ deadline で
    // 競り、**どちらが先に arena を取るかが登録順に依存する**。`manual` は
    // recognizer を一切足さないので競りが消える。⚠ **ホバーは残る**
    // （`RawTooltip.triggerMode` の doc に "does not affect mouse devices"）。
    //
    // ⚠ `post_tile.dart` の `_maybeDesktopTooltip`（#753 / #754）と違い
    // **`isDesktop` で分けない。**Windows のタッチ機は `isDesktop` が true
    // なのに長押しができるので、包む / 包まないの判定が破れる。
    return Tooltip(
      message: '通知（長押しでアカウントを選択）',
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        onLongPress: () => _showMenu(context),
        child: button,
      ),
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    // PopupMenuItem + ListTile は default height 制約（48dp）と ListTile の
    // 推奨高（56dp+）がぶつかって 2 つ目以降が見切れる事象があったため、
    // Row ベースのコンパクトなレイアウトに変更している。
    final selection = await showMenu<String>(
      context: context,
      position: position,
      items: const [
        PopupMenuItem(
          value: '/notifications/all',
          child: Row(
            children: [
              Icon(Icons.notifications_active_outlined, size: 20),
              SizedBox(width: 12),
              Text('すべての通知'),
            ],
          ),
        ),
        PopupMenuItem(
          value: '/notifications',
          child: Row(
            children: [
              Icon(Icons.notifications_outlined, size: 20),
              SizedBox(width: 12),
              Text('このアカウントの通知'),
            ],
          ),
        ),
      ],
    );
    if (selection != null && context.mounted) context.push(selection);
  }
}
