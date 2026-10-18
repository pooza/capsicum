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

  /// 投稿単位で登録された数（Web の「この投稿をフィルター」）。capsicum は
  /// 中身を扱わないが、**キーワードが 0 件でも空のフィルターではない**ことを
  /// 知るために数だけ持つ (#1293)。
  final int statusCount;

  /// capsicum が知らない `context` の値（上流で増えたもの）。⚠ 編集して保存する
  /// ときに**そのまま送り返す**。読み捨てると、保存のたびにサーバー側で消える (#1293)。
  final List<String> unknownContexts;

  /// capsicum が知らない `filter_action` の値。[action] は warn として読むが、
  /// 動作を変えずに保存するときはこちらを送り返す (#1293)。
  final String? unknownAction;

  const ServerFilter({
    required this.id,
    required this.title,
    required this.contexts,
    required this.action,
    this.expiresAt,
    this.keywords = const [],
    this.statusCount = 0,
    this.unknownContexts = const [],
    this.unknownAction,
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

  /// [ServerFilter.unknownContexts] をそのまま送り返す分 (#1293)。
  final List<String> unknownContexts;

  /// 非 null なら [action] の代わりにこれを送る（[ServerFilter.unknownAction] を
  /// 変えずに保存するとき・#1293）。
  final String? rawAction;

  const FilterDraft({
    required this.title,
    required this.contexts,
    required this.action,
    this.expiry = const NoFilterExpiry(),
    this.keywords = const [],
    this.removedKeywordIds = const [],
    this.unknownContexts = const [],
    this.rawAction,
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
