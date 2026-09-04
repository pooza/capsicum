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
