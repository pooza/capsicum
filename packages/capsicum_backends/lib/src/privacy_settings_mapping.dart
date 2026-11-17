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
      discoverable: _flag(json, 'discoverable'),
      indexable: _flag(json, 'indexable'),
      hideCollections: _flag(json, 'hide_collections'),
      searchEngineHidden: _flag(json, 'noindex'),
      searchEngineEditable: false,
    );

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
