import '../../model/collection.dart';

/// Mastodon 4.6 Collections (FEP-7aa9) サポートを宣言する mixin (#722 / #742)。
///
/// 最大25アカウントを束ねるキュレーション。Misskey に等価機能はないため
/// Mastodon アダプタにのみ mixin し、UI は `adapter is CollectionsSupport` で
/// gate する。通知描画 (#741) は Collection 最小モデルだけで完結しており、この
/// mixin は一覧閲覧・opt-out・作成/編集の操作系を担う。
abstract mixin class CollectionsSupport {
  /// 指定アカウントが**所有する**コレクション一覧
  /// （`GET /api/v1/accounts/:id/collections`）。offset ページングだが 1
  /// アカウントの保有数は小さいため v1 は先頭ページのみ取得する。
  Future<List<Collection>> getAccountCollections(String accountId);

  /// 指定アカウントが**載せられている**コレクション一覧
  /// （`GET /api/v1/accounts/:id/in_collections`）。各 Collection の `items` に
  /// 自分の item が含まれ、revoke に使う item id を引ける。
  Future<List<Collection>> getInCollections(String accountId);

  /// コレクション詳細＋メンバーアカウント
  /// （`GET /api/v1/collections/:id`、CollectionWithAccounts）。
  Future<CollectionDetail> getCollection(String id);

  /// コレクション作成（`POST /api/v1/collections`）。
  Future<Collection> createCollection({
    required String name,
    String? description,
    String? tagName,
    bool? discoverable,
    bool? sensitive,
    List<String> accountIds = const [],
  });

  /// コレクション更新（`PATCH /api/v1/collections/:id`）。
  Future<Collection> updateCollection(
    String id, {
    String? name,
    String? description,
    String? tagName,
    bool? discoverable,
    bool? sensitive,
  });

  /// コレクション削除（`DELETE /api/v1/collections/:id`）。
  Future<void> deleteCollection(String id);

  /// メンバー追加（`POST /api/v1/collections/:id/items`、body `account_id`）。
  Future<CollectionItem> addCollectionItem(
    String collectionId,
    String accountId,
  );

  /// メンバー削除（所有者操作、`DELETE /api/v1/collections/:id/items/:itemId`）。
  Future<void> removeCollectionItem(String collectionId, String itemId);

  /// 自分を外す＝opt-out（載せられた本人のみ、
  /// `POST /api/v1/collections/:id/items/:itemId/revoke`）。
  Future<void> revokeCollectionItem(String collectionId, String itemId);
}
