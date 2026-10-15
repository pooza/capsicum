import '../../../capsicum_core.dart';

/// サーバーに保存されたフィルターのキーワード 1 つ (#1047)。
class FilterKeyword {
  /// サーバー上の id。⚠ **新しく足すキーワードは null。**
  final String? id;
  final String keyword;

  /// 単語全体にだけ一致させるか（Mastodon の `whole_word`）。
  final bool wholeWord;

  const FilterKeyword({this.id, required this.keyword, this.wholeWord = true});
}

/// サーバーに保存されたフィルター 1 つ (#1047)。Mastodon の v2 フィルター。
///
/// ⚠ **Misskey のワードミュートとは畳まない**（`docs/filter-management-plan.md`
/// 決定済み事項 4）。あちらは `WordMuteSupport`（#1290）。
class ServerFilter {
  final String id;
  final String title;
  final Set<FilterContext> contexts;
  final FilterAction action;

  /// 期限。null は無期限。
  final DateTime? expiresAt;
  final List<FilterKeyword> keywords;

  const ServerFilter({
    required this.id,
    required this.title,
    required this.contexts,
    required this.action,
    this.expiresAt,
    this.keywords = const [],
  });

  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !expiresAt!.isAfter(now);
}

/// フィルターの期限の指定 (#1047)。
sealed class FilterExpiry {
  const FilterExpiry();
}

/// 期限を変えない（編集のときだけ）。
class KeepFilterExpiry extends FilterExpiry {
  const KeepFilterExpiry();
}

/// 無期限にする。
class NoFilterExpiry extends FilterExpiry {
  const NoFilterExpiry();
}

/// 今から [duration] 後に切れる。
class FilterExpiresIn extends FilterExpiry {
  final Duration duration;
  const FilterExpiresIn(this.duration);
}

/// フィルターを作る / 変えるときの中身 (#1047)。
class FilterDraft {
  final String title;
  final Set<FilterContext> contexts;
  final FilterAction action;
  final FilterExpiry expiry;

  /// 残すキーワード（新しいものは id が null）。
  final List<FilterKeyword> keywords;

  /// 消すキーワードの id（編集のときだけ）。
  final List<String> removedKeywordIds;

  const FilterDraft({
    required this.title,
    required this.contexts,
    required this.action,
    this.expiry = const NoFilterExpiry(),
    this.keywords = const [],
    this.removedKeywordIds = const [],
  });
}

/// サーバーに保存するフィルターの管理 (#1047)。Mastodon の `api/v2/filters`。
///
/// ⚠ **保存は、読み込み済みの投稿には効かない。**一致の判定はサーバーが投稿を
/// 返すときに行うため（Mastodon Web も同じ）。画面はその旨を出す。
abstract mixin class FilterSupport {
  /// すべてのフィルター（期限切れも含む）。
  Future<List<ServerFilter>> getFilters();

  Future<ServerFilter> createFilter(FilterDraft draft);

  /// キーワードの増減は [FilterDraft.keywords] と
  /// [FilterDraft.removedKeywordIds] で同じ要求に載せる。
  Future<ServerFilter> updateFilter(String id, FilterDraft draft);

  Future<void> deleteFilter(String id);
}
