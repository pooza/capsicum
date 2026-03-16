import '../../model/user.dart';

abstract mixin class ProfileEditSupport {
  /// Returns the maximum number of profile fields allowed, or null if unlimited.
  Future<int?> getMaxProfileFields();

  /// Update the current user's profile. Only non-null values are sent.
  Future<User> updateProfile({
    String? displayName,
    String? description,
    String? avatarFilePath,
    String? bannerFilePath,
    List<UserField>? fields,
  });
}
