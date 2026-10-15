/// 投稿にかかったフィルターの動作 (#1289)。
///
/// - [warn]: 投稿を畳み、「表示する」で開く
/// - [hide]: 一覧から落とす。⚠ 落とさない一覧（下の [FilterContext] の弱め）では
///   [warn] として描く
/// - [blur]: 本文は見せ、メディアだけをぼかす（Mastodon 4.7〜）
enum FilterAction { hide, warn, blur }

/// フィルターの適用先 (#1289)。値は Mastodon の `context` と同じ。
///
/// ⚠⚠ **一致の判定はサーバー、どの画面で伏せるかはクライアントの責務。**
/// Mastodon は一致したフィルターを `context` に関係なくすべて `filtered[]` に
/// 載せて返す。capsicum の画面との対応は `docs/filter-management-plan.md`
/// 決定済み事項 2（Mastodon Web の `utils/filters.ts` に揃えてある）。
enum FilterContext {
  home,
  notifications,
  public,
  thread,
  account;

  /// Mastodon の `context` の文字列から。知らない値は null。
  static FilterContext? fromName(String name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// 投稿に一致したフィルター 1 件 (#1289)。
class FilterMatch {
  final FilterAction action;
  final String? title;

  /// 適用先。⚠ **null は「全画面」**（Misskey のワードミュート。Misskey には
  /// 適用先の概念が無い）。空集合は「どこにも適用しない」。
  final Set<FilterContext>? contexts;

  const FilterMatch({required this.action, this.title, this.contexts});

  bool appliesTo(FilterContext? context) =>
      context == null || contexts == null || contexts!.contains(context);
}

/// [FilterMatch] の一覧を、見ている画面について解決した結果。
class FilterVerdict {
  final FilterAction action;

  /// 採ったフィルターのタイトルを「、」で連結したもの（Mastodon Web と同じ）。
  /// タイトルが 1 つも無ければ null。
  final String? title;

  const FilterVerdict({required this.action, this.title});
}

/// [matches] を [context] の画面について解決する。当たらなければ null。
///
/// - [context] が null なら適用先を問わない（画面の種別が分からないところ用）
/// - 採ったものの中に hide があれば hide、無ければ blur があれば blur、それ以外は warn
/// - [weakenHide] が true なら hide を warn にする。⚠ 詳細（スレッド）・
///   ブックマーク・お気に入り・検索がこれ（2026-10-15 pooza 判断・Mastodon Web と同じ）。
///   開いた本人が読もうとしている場所で投稿を消さない
FilterVerdict? resolveFilterMatches(
  List<FilterMatch> matches,
  FilterContext? context, {
  bool weakenHide = false,
}) {
  final applied = [
    for (final match in matches)
      if (match.appliesTo(context)) match,
  ];
  if (applied.isEmpty) return null;
  bool has(FilterAction action) => applied.any((m) => m.action == action);
  var action = has(FilterAction.hide)
      ? FilterAction.hide
      : has(FilterAction.blur) && !has(FilterAction.warn)
      ? FilterAction.blur
      : FilterAction.warn;
  if (weakenHide && action == FilterAction.hide) action = FilterAction.warn;
  final titles = <String>[];
  for (final match in applied) {
    final title = match.title;
    if (title != null && title.isNotEmpty && !titles.contains(title)) {
      titles.add(title);
    }
  }
  return FilterVerdict(
    action: action,
    title: titles.isEmpty ? null : titles.join('、'),
  );
}
