import '../../model/page.dart';
import '../../model/timeline_query.dart';

/// Misskey の Pages 機能 (#186) サポートを宣言する mixin。
///
/// v1 (#186) は読み取り専用。like / unlike は #615、AiScript 動的ブロック
/// 対応は #616 で別途扱う。
abstract mixin class PagesSupport {
  /// 指定ユーザーが公開している Page の一覧。
  ///
  /// Misskey の `POST /api/users/pages` 相当。
  Future<List<Page>> getUserPages(String userId, {TimelineQuery? query});

  /// 指定 ID のページを取得する。
  ///
  /// Misskey の `POST /api/pages/show` を `{pageId}` パラメータで叩く。
  Future<Page> getPageById(String pageId);

  /// `(username, name)` の組でページを取得する。
  ///
  /// 外部リンク `https://host/@username/pages/<name>` からの遷移で使う。
  /// Misskey の `POST /api/pages/show` を `{name, username}` パラメータで叩く。
  Future<Page> getPageByName({required String username, required String name});

  /// サーバーが featured 扱いしているページ一覧 (任意)。
  /// 実装が override しなければ空リストを返す (= ピックアップ表示を出さない)。
  Future<List<Page>> getFeaturedPages({TimelineQuery? query}) async => const [];

  /// 認証ユーザーが like 済みのページ一覧。
  ///
  /// Misskey の `POST /api/i/page-likes` 相当。サーバーが認証ユーザーの
  /// like 履歴を保持していない場合は空リストを返す。
  Future<List<Page>> getLikedPages({TimelineQuery? query}) async => const [];
}
