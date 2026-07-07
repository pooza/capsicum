/// Mastodon 4.6 Collections (FEP-7aa9) のドメインモデル。
///
/// 最小形（id / name / url / itemCount）は通知描画 (#741) が使う。一覧閲覧 /
/// opt-out (#742) / 作成・編集 (#722) 向けに additive でフィールドを足している。
/// 追加分は未対応サーバー・軽量ペイロード（通知同梱）では null / 空になる。
library;

import 'user.dart';

/// コレクション一覧の 1 ページ（offset ページング、#802）。[nextOffset] が
/// non-null なら次ページがある（Link ヘッダ rel="next" の offset）。null で終端。
typedef CollectionPage = ({List<Collection> collections, int? nextOffset});

/// コレクション内の 1 メンバー（`REST::CollectionItemSerializer`）。
/// `state` は招待の承認状態で、revoke（opt-out）対象かの判定に使う。
enum CollectionItemState { pending, accepted, rejected, revoked, unknown }

CollectionItemState collectionItemStateFromString(String? s) => switch (s) {
  'pending' => CollectionItemState.pending,
  'accepted' => CollectionItemState.accepted,
  'rejected' => CollectionItemState.rejected,
  'revoked' => CollectionItemState.revoked,
  _ => CollectionItemState.unknown,
};

class CollectionItem {
  final String id;
  final CollectionItemState state;

  /// 承認/保留中のみ露出する（rejected/revoked は account_id を返さない）。
  final String? accountId;

  const CollectionItem({
    required this.id,
    this.state = CollectionItemState.unknown,
    this.accountId,
  });
}

class Collection {
  final String id;
  final String name;

  /// コレクションの公開 URL（外部遷移用）。
  final String? url;

  /// 収録アイテム数（分かる場合）。
  final int? itemCount;

  /// 説明文（詳細/編集で使う）。
  final String? description;

  /// 所有者アカウント ID。
  final String? ownerAccountId;

  /// 連合上で discoverable か。
  final bool? discoverable;

  /// センシティブ指定。
  final bool? sensitive;

  /// 紐づくタグ名（コレクションはタグに束ねられる）。
  final String? tagName;

  /// メンバー item の一覧（`REST::CollectionSerializer` の `items`）。
  /// in_collections の各コレクションから「自分の item」を引いて revoke する
  /// のに使う (#742)。軽量ペイロードでは空。
  final List<CollectionItem> items;

  const Collection({
    required this.id,
    required this.name,
    this.url,
    this.itemCount,
    this.description,
    this.ownerAccountId,
    this.discoverable,
    this.sensitive,
    this.tagName,
    this.items = const [],
  });
}

/// `GET /api/v1/collections/:id`（`REST::CollectionWithAccountsSerializer`）の
/// 結果。コレクション本体＋メンバーアカウント（先頭は所有者）。
class CollectionDetail {
  final Collection collection;
  final List<User> accounts;

  const CollectionDetail({required this.collection, this.accounts = const []});
}

/// account の `feature_approval`（Mastodon 4.6、#742）。誰がこのアカウントを
/// コレクションに載せてよいかの承認ポリシー。`automatic` / `manual` は各方針に
/// 該当する対象キー、`currentUser` は「今の閲覧ユーザーに適用される方針」。
class FeatureApproval {
  final List<String> automatic;
  final List<String> manual;
  final String? currentUser;

  const FeatureApproval({
    this.automatic = const [],
    this.manual = const [],
    this.currentUser,
  });
}
