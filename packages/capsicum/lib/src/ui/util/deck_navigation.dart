import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../model/deck_column.dart';

/// デッキのカラムの中であることを示す (#1148)。
///
/// ⚠ **`InheritedTheme` なのは、カラムから開いたシート・ダイアログ・メニューの中
/// にも持ち込むため**（`ProviderScopeCarrier` と同じ仕組み・#1149）。投稿の長押し
/// シートの「プロフィールを表示」やハッシュタグのシートから開いても、元のカラムの
/// 右隣に足される。
///
/// ⚠ 全画面の push（投稿フォーム等）の先には持ち込まれない。そこから開くものは
/// 今どおり push になる。
class DeckColumnScope extends InheritedTheme {
  const DeckColumnScope({
    super.key,
    required this.column,
    required this.onOpen,
    required super.child,
  });

  /// 開く元のカラム。新しいカラムはこの右隣に、このアカウントで足す。
  final DeckColumn column;

  /// カラムを足す（デッキ画面が渡す。列への挿入と、足したカラムを見える位置まで
  /// 送るのを受け持つ）。
  final void Function(DeckColumn from, TabType tab, Object? seed) onOpen;

  static DeckColumnScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DeckColumnScope>();

  @override
  Widget wrap(BuildContext context, Widget child) =>
      DeckColumnScope(column: column, onOpen: onOpen, child: child);

  @override
  bool updateShouldNotify(DeckColumnScope oldWidget) =>
      // ⚠ onOpen はメソッドのテアオフで渡るので、identical ではなく == で比べる
      // （テアオフはビルドのたびに別インスタンスだが等価）。
      !identical(column, oldWidget.column) || onOpen != oldWidget.onOpen;
}

/// 投稿（スレッド）を開く (#1148)。
///
/// ⚠⚠ **`context.push('/post' …)` を直接書かないこと。**デッキのカラムの中では
/// 元のカラムの右隣に新しいカラムとして開き（決定済み事項 9）、それ以外では今どおり
/// 画面遷移する。直接 push すると、**カラム B から開いたスレッドがアカウント A
/// （ルート）で動く。**`deck_navigation_guard_test` が止める。
void openPost(BuildContext context, Post post) {
  final deck = DeckColumnScope.maybeOf(context);
  if (deck != null) {
    deck.onOpen(deck.column, PostThreadTab(post.id), post);
    return;
  }
  context.push('/post', extra: post);
}

/// プロフィールを開く (#1148)。振り分けは [openPost] と同じ。
void openProfile(BuildContext context, User user) {
  final deck = DeckColumnScope.maybeOf(context);
  if (deck != null) {
    deck.onOpen(deck.column, ProfileTab(user.id), user);
    return;
  }
  context.push('/profile', extra: user);
}

/// ハッシュタグのタイムラインを開く (#1148)。振り分けは [openPost] と同じ。
///
/// [tag] は先頭の `#` を除いたタグ名（AND 条件の `a+b` もそのまま）。
void openHashtag(BuildContext context, String tag) {
  final deck = DeckColumnScope.maybeOf(context);
  if (deck != null) {
    deck.onOpen(deck.column, HashtagTab(tag), null);
    return;
  }
  context.push('/hashtag/$tag');
}
