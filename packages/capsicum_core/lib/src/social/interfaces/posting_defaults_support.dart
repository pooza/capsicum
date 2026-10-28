import '../../model/post_scope.dart';
import '../../model/user.dart';

/// サーバー側の投稿の既定を変える (#1210)。Mastodon の
/// `PATCH /api/v1/accounts/update_credentials` の `source[*]`。
///
/// 投稿フォームは新規の投稿を開くとき、これらを [User] から読んで使う
/// （#1185 / #1194）。端末側に別の既定は持たない。
///
/// ⚠ **Mastodon だけ。**Misskey の `i/update` にも等価物はあるが、今回は作らない
/// （2026-10-18 pooza 判断）。
abstract mixin class PostingDefaultsSupport {
  /// null の項目は変えない。返すのは更新後の自分。
  ///
  /// - [scope]: 公開・ひかえめな公開・フォロワーのみ（⚠ Mastodon は DM を既定に
  ///   できない）
  /// - [quotePolicy]: `public` / `followers` / `nobody`（4.5〜）
  /// - [spoilerField]: 投稿欄の CW を最初から開くか（5.0〜・#1322）
  Future<User> updatePostingDefaults({
    PostScope? scope,
    bool? sensitive,
    String? language,
    String? quotePolicy,
    bool? spoilerField,
  });
}
