import '../../model/user.dart';

abstract mixin class ProfileEditSupport {
  /// Returns the maximum number of profile fields allowed, or null if unlimited.
  Future<int?> getMaxProfileFields();

  /// アバター/ヘッダー画像を「削除してデフォルトに戻す」導線を出せるか（#736）。
  /// Mastodon 4.6 の `DELETE /api/v1/profile/{avatar,header}` が該当。未対応
  /// バックエンドでは false（削除ボタンを出さない）。
  bool get supportsProfileImageRemoval => false;

  /// Update the current user's profile. Only non-null values are sent.
  ///
  /// [removeAvatar] / [removeHeader] が true のとき該当画像をデフォルトへ戻す
  /// （[supportsProfileImageRemoval] が true のバックエンドのみ有効、#736）。
  /// 画像の差し替え（avatarFilePath 等）と削除は排他で、UI 側で択一にする。
  Future<User> updateProfile({
    String? displayName,
    String? description,
    String? avatarFilePath,
    String? bannerFilePath,
    List<UserField>? fields,
    bool removeAvatar = false,
    bool removeHeader = false,
  });
}
