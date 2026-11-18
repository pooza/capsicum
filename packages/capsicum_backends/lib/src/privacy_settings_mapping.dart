import 'package:capsicum_core/capsicum_core.dart';

/// プライバシーとつながりやすさの設定を、サーバーの JSON から組む (#1375)。
///
/// ⚠ **キーが無ければ null（項目を出さない）**。キーがあって値が null のとき
/// （Mastodon の `discoverable` の未設定・`hide_collections` の未設定）は false。
bool? _flag(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) return null;
  final value = json[key];
  return value is bool ? value : false;
}

/// Mastodon の `verify_credentials` / `update_credentials` の応答から。
///
/// ⚠ `noindex` は自分（ローカルのアカウント）にだけ付く。**API で変えられない**
/// ので [PrivacySettings.searchEngineEditable] は false（Web へ誘導する）。
PrivacySettings mastodonPrivacySettingsFromJson(Map<String, dynamic> json) =>
    PrivacySettings(
      locked: _flag(json, 'locked'),
      discoverable: _flag(json, 'discoverable') ?? _pleromaDiscoverable(json),
      indexable: _flag(json, 'indexable'),
      hideCollections: _flag(json, 'hide_collections'),
      searchEngineHidden: _flag(json, 'noindex'),
      searchEngineEditable: false,
    );

/// Akkoma（Pleroma 系）の `discoverable` は最上位ではなく `source.pleroma` の下に
/// ある（`account_view.ex`）。最上位だけを読むと null になって「おすすめへの掲載」が
/// 出なかった（v2.13 のリリース前レビュー）。書き込みは Mastodon と同じ
/// `discoverable` で効く（`account_controller.ex`）。
bool? _pleromaDiscoverable(Map<String, dynamic> json) {
  final source = json['source'];
  if (source is! Map<String, dynamic>) return null;
  final pleroma = source['pleroma'];
  if (pleroma is! Map<String, dynamic>) return null;
  return _flag(pleroma, 'discoverable');
}

/// Misskey の `/api/i` / `i/update` の応答から。
///
/// ⚠ `requireSigninToViewContents` は **false のときキーごと省かれる**
/// （`UserEntityService.ts` の `=== false ? undefined : true`）ので、無ければ
/// false と読む（ほかの項目と違い、キーが無いことを「出さない」と読まない）。
PrivacySettings misskeyPrivacySettingsFromJson(Map<String, dynamic> json) =>
    PrivacySettings(
      locked: _flag(json, 'isLocked'),
      discoverable: _flag(json, 'isExplorable'),
      searchEngineHidden: _flag(json, 'noCrawle'),
      searchEngineEditable: true,
      autoAcceptFollowed: _flag(json, 'autoAcceptFollowed'),
      publicReactions: _flag(json, 'publicReactions'),
      followingVisibility: FollowListVisibility.fromServer(
        json['followingVisibility'],
      ),
      followersVisibility: FollowListVisibility.fromServer(
        json['followersVisibility'],
      ),
      hideOnlineStatus: _flag(json, 'hideOnlineStatus'),
      preventAiLearning: _flag(json, 'preventAiLearning'),
      requireSigninToViewContents: json['requireSigninToViewContents'] == true,
    );
