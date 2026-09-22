import '../../model/featured_tag.dart';

/// プロフィールの掲載タグ（フィーチャータグ）サポートを宣言する mixin (#1075)。
///
/// Misskey に等価機能はないため Mastodon アダプタにのみ mixin し、UI は
/// `adapter is FeaturedTagSupport` で gate する。⚠ いまは**読む側だけ**。
/// 自分の掲載タグの追加・削除（`POST / DELETE /api/v1/featured_tags`）は
/// 必要になったらここへ足す。
abstract mixin class FeaturedTagSupport {
  /// 指定アカウントの掲載タグ（`GET /api/v1/accounts/:id/featured_tags`）。
  /// ページングは無い（サーバーが全件を返す）。
  Future<List<FeaturedTag>> getFeaturedTags(String accountId);
}
