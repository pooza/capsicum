import '../../model/featured_tag.dart';

/// 掲載できるタグの上限 (#1075)。Mastodon の `FeaturedTag::LIMIT`（サーバー設定で
/// 変えられない定数）。超えると `POST /api/v1/featured_tags` が 422 を返す。
const featuredTagLimit = 10;

/// プロフィールの掲載タグ（フィーチャータグ）サポートを宣言する mixin (#1075)。
///
/// Misskey に等価機能はないため Mastodon アダプタにのみ mixin し、UI は
/// `adapter is FeaturedTagSupport` で gate する。
abstract mixin class FeaturedTagSupport {
  /// 指定アカウントの掲載タグ（`GET /api/v1/accounts/:id/featured_tags`）。
  /// ページングは無い（サーバーが全件を返す）。
  Future<List<FeaturedTag>> getFeaturedTags(String accountId);

  /// 自分のプロフィールにタグを掲載する（`POST /api/v1/featured_tags`）。
  /// [name] は `#` を含まないタグ名。⚠ 掲載済みのタグを渡すとサーバーは既存の
  /// ものをそのまま返す（重複はできない）。
  Future<FeaturedTag> featureTag(String name);

  /// 自分のプロフィールから掲載を外す（`DELETE /api/v1/featured_tags/:id`）。
  Future<void> unfeatureTag(String id);

  /// 掲載の候補（`GET /api/v1/featured_tags/suggestions`）。自分が最近使った
  /// タグのうち、**まだ掲載していないもの**の名前（`#` を含まない）。
  Future<List<String>> getFeaturedTagSuggestions();
}
