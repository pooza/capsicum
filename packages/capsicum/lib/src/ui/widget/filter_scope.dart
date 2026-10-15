import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/widgets.dart';

/// この下に描かれる投稿の、フィルターの適用先 (#1289)。
///
/// ⚠⚠ **投稿タイルは自分がどの画面にいるかを知らない**ので、一覧の外側から渡す。
/// タイルの呼び出し元ごとに引数を通す形にしないのは、呼び出し元が多く、デッキでも
/// 同じタイルを使うため（`docs/filter-management-plan.md` 決定済み事項 2）。
///
/// 包まれていない画面では、タイルは適用先を問わずに判定する（以前と同じ）。
class FilterScope extends InheritedWidget {
  const FilterScope({
    super.key,
    required this.filterContext,
    this.weakenHide = false,
    required super.child,
  });

  final FilterContext filterContext;

  /// hide を warn に弱めるか。詳細（スレッド）・ブックマーク・お気に入り・検索が
  /// これ（2026-10-15 pooza 判断・Mastodon Web と同じ）。
  final bool weakenHide;

  static FilterScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FilterScope>();

  @override
  bool updateShouldNotify(FilterScope oldWidget) =>
      filterContext != oldWidget.filterContext ||
      weakenHide != oldWidget.weakenHide;

  /// タイムライン系のタブなら [FilterScope] で包む。それ以外のタブはそのまま返す
  /// （埋め込まれた画面の側が自分で包む）。ホームのタブとデッキのカラムで共有する。
  static Widget wrapTab(TabType tab, Widget child) {
    final filterContext = filterContextForTab(tab);
    if (filterContext == null) return child;
    return FilterScope(filterContext: filterContext, child: child);
  }
}

/// タブ → フィルターの適用先 (#1289)。タイムライン系のタブ以外は null。
///
/// 対応は Mastodon Web（`utils/filters.ts`）と同じ。ホームとリストは `home`、
/// それ以外の公開系（ハッシュタグ・チャンネルを含む）と DM は `public`。
FilterContext? filterContextForTab(TabType tab) => switch (tab) {
  TimelineTab(:final type) =>
    type == TimelineType.home ? FilterContext.home : FilterContext.public,
  ListTab() => FilterContext.home,
  HashtagTab() || ChannelTab() => FilterContext.public,
  _ => null,
};
