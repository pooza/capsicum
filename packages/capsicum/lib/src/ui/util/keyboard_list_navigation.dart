import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// タイムライン / スレッドを ↑ ↓ キーだけで辿るための共通ロジック (#849)。
///
/// ホーム ([HomeScreen]) とスレッド ([PostDetailScreen]) は同じ
/// `ScrollablePositionedList` + `ItemScrollController` + `PostTile` 構成なので、
/// 選択位置の保持・キーハンドラ・スクロール追従をこの mixin に集約して共用する。
///
/// 設計上の決めごと:
///
/// - **選択はビュー状態**なので provider に載せず画面ローカルに持つ。タイムラインの
///   provider は autoDispose で画面遷移ごとに捨てられるため、選択だけを別に永続化
///   する意味がない。
/// - **null 始点**にする。キーを押すまで選択ハイライトを出さないので、ハード
///   ウェアキーボードの無い端末では何も変わらない。プラットフォーム / 画面幅の
///   分岐を増やさずに済む（デスクトップ設計指針）。
/// - 修飾キー付きは扱わない。メニューバーの `CallbackShortcuts`（⌘F 等）は
///   修飾つきなので、このノードで ignore すればそのまま上位へ bubble する。
mixin KeyboardListNavigation<T extends StatefulWidget> on State<T> {
  final FocusNode _keyboardListFocusNode = FocusNode(
    debugLabel: 'keyboardListNavigation',
  );
  int? _selectedIndex;
  bool _initialFocusRequested = false;

  /// リストのスクロール制御。ホスト画面が `ScrollablePositionedList` に渡している
  /// ものと同一インスタンスであること。
  ItemScrollController get keyboardListScrollController;

  /// 可視判定に使う positions listener。ホスト画面がリストに渡しているものと同一
  /// インスタンスであること。
  ItemPositionsListener get keyboardListPositionsListener;

  /// 選択対象になる要素数（末尾のローディング行等は含めない）。
  int get keyboardListItemCount;

  /// Enter / → で選択中の要素を開く。
  void onKeyboardListActivate(int index);

  /// 未選択の状態で最初にキーが押されたときに選ぶ index。既定は先頭可視 index。
  int get keyboardListInitialIndex {
    final positions = keyboardListPositionsListener.itemPositions.value;
    if (positions.isEmpty) return 0;
    return positions
        .where((p) => p.itemTrailingEdge > 0)
        .fold<int>(
          positions.first.index,
          (min, p) => p.index < min ? p.index : min,
        );
  }

  /// 現在キーボードで選択している index。未選択なら null。
  int? get keyboardSelectedIndex => _selectedIndex;

  /// 選択を解除する（タブ切替など、リストの中身が別物に入れ替わったとき）。
  void resetKeyboardSelection() {
    if (_selectedIndex == null) return;
    setState(() => _selectedIndex = null);
  }

  /// 選択を「次フレームで」解除する (#928)。
  ///
  /// build 中（`data:` / `loading:` / `error:` ビルダーや `ref.listen`）からは
  /// setState できないため、後始末をフレーム後へ逃がす。リストの中身が別物へ
  /// 入れ替わった / 消えたときにホスト画面から呼ぶ。各画面へ手書きコピーすると
  /// 画面が増えるたびに取りこぼす（#849 で home / post_detail に別々に置いた同型
  /// コードが Codex 3 巡目で顕在化した）ため mixin へ集約した。
  void resetKeyboardSelectionAfterFrame() {
    if (_selectedIndex == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) resetKeyboardSelection();
    });
  }

  /// リスト本体を包んでキー入力を受け取れるようにする。
  ///
  /// テキスト入力欄を内側に含めないこと（欄にフォーカスがあるときの ↑ ↓ は
  /// IME の候補選択やカーソル移動に使われるため、ここで奪ってはいけない）。
  Widget wrapKeyboardListNavigation({required Widget child}) {
    // 初回だけ明示的にフォーカスを取る。ホームではメニューバー (#841) が
    // `Focus(autofocus: true)` で既定フォーカスを先に確保しており、キーイベントは
    // 祖先へしか流れないため、autofocus 頼みだとこの mixin までイベントが来ない。
    // 画面が立ち上がった直後の 1 回だけなので、入力欄からフォーカスを奪うことはない。
    if (!_initialFocusRequested) {
      _initialFocusRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _keyboardListFocusNode.context != null) {
          _keyboardListFocusNode.requestFocus();
        }
      });
    }
    return Focus(
      focusNode: _keyboardListFocusNode,
      // タブ切替等でこのサブツリーが作り直されたときに拾い直す。
      autofocus: true,
      // Tab キーの巡回先には出さない（見えない止まり木を作らない）。
      skipTraversal: true,
      onKeyEvent: _handleKey,
      child: child,
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final count = keyboardListItemCount;
    if (count <= 0) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1, count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1, count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.arrowRight) {
      final index = _selectedIndex;
      if (index == null || index >= count) return KeyEventResult.ignored;
      onKeyboardListActivate(index);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveSelection(int delta, int count) {
    final current = _selectedIndex;
    final int next;
    if (current == null) {
      // 初回はカーソルを出すだけ（いきなり 1 件ずれた位置から始めない）。
      next = keyboardListInitialIndex.clamp(0, count - 1);
    } else {
      // リストが縮んでいる（リフレッシュ直後など）場合に備えて先に clamp する。
      next = (current.clamp(0, count - 1) + delta).clamp(0, count - 1);
    }
    if (next != current) setState(() => _selectedIndex = next);
    _revealSelection(next, downward: delta > 0);
  }

  /// 選択が画面外／見切れているときだけスクロールで寄せる。すでに全体が見えて
  /// いるならリストは動かさない（1 件ずつ画面が飛ぶのを防ぐ）。
  void _revealSelection(int index, {required bool downward}) {
    final controller = keyboardListScrollController;
    if (!controller.isAttached) return;
    final positions = keyboardListPositionsListener.itemPositions.value.where(
      (p) => p.index == index,
    );
    if (positions.isNotEmpty) {
      final position = positions.first;
      if (position.itemLeadingEdge >= 0 && position.itemTrailingEdge <= 1) {
        return;
      }
    }
    controller.scrollTo(
      index: index,
      // 下方向は画面下寄り、上方向は上寄りに置く（カーソルの進行方向に画面が
      // ついてくる形にして、1 件進むたびに大きく飛ばない）。
      alignment: downward ? 0.7 : 0.1,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _keyboardListFocusNode.dispose();
    super.dispose();
  }
}
