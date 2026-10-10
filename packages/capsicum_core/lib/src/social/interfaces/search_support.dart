import '../../model/post.dart';
import '../../model/user.dart';

class SearchResults {
  final List<Post> posts;
  final List<User> users;
  final List<String> hashtags;

  /// 本文検索がこのサーバーで提供されていない (#1041)。
  ///
  /// ⚠ **「0 件」と「そもそも引けない」を区別するために要る。**Misskey は
  /// 全文検索バックエンド（Meilisearch / pgroonga 等）を別立てで持つ構成で、
  /// 未設定のサーバーは `notes/search` に `UNAVAILABLE` を返す。実際
  /// ダイスキー・きゅあすきーとも未設定（2026-09-04 実測）。
  ///
  /// ⚠ **host で分岐しない。**「機能の有無を検出して出し分ける」形に寄せる
  /// （probing ベースの基本戦略・モロヘイヤ検出と同じ考え方）。
  final bool postSearchUnavailable;

  const SearchResults({
    this.posts = const [],
    this.users = const [],
    this.hashtags = const [],
    this.postSearchUnavailable = false,
  });
}

abstract mixin class SearchSupport {
  Future<SearchResults> search(String query);
  Future<List<User>> searchUsers(String query, {int? limit});
  Future<List<String>> searchHashtags(String query, {int? limit});
}

/// 検索結果の種別。続きを読むときに 1 つだけ指定する (#1202)。
enum SearchKind { users, posts, hashtags }

/// 検索結果の続きを種別ごとに読める (#1202)。
///
/// ⚠ **[SearchSupport.search] は 3 種別をまとめて 1 ページだけ返す。**続きを
/// 持たないと、21 件目以降が「それだけしか無い」ように見える。
///
/// ⚠ **種別をまとめて続きを読む口は作らない。**Mastodon の `offset` は
/// `type` を指定したときしか効かないので、まとめて送ると同じ 1 ページ目が
/// 返り続ける。
abstract mixin class SearchPagingSupport {
  /// [SearchSupport.search] と [searchMore] が 1 回に返す最大件数。
  ///
  /// ⚠ **「まだ続きがあるか」の判定に使う。**返ってきた件数がこれ未満なら
  /// 終端。サーバーは総数を返さないので、ほかに知る手段が無い。
  int get searchPageSize;

  /// [kind] の結果を、先頭から [offset] 件飛ばして 1 ページ読む。
  ///
  /// 返る [SearchResults] は [kind] のリストだけが埋まる。
  Future<SearchResults> searchMore(
    String query,
    SearchKind kind, {
    required int offset,
  });
}
