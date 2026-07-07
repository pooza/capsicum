import '../../model/user.dart';

/// [ProfileEditSupport.updateProfile] が本文（表示名・自己紹介・項目）の更新に
/// 成功した後、画像削除などの後続ステップの一部だけ失敗したことを表す。
///
/// Mastodon は本文更新（`PATCH update_credentials`）と画像削除（4.6 の
/// `DELETE profile/{avatar,header}`）が別リクエストで、途中失敗しても本文は
/// サーバーに保存済みになる。呼び出し側はこの例外を捕捉して [user]（成功分を
/// 反映した最新状態）で画面を更新しつつ、[failedSteps] を使って「本文は保存
/// 済み・画像削除だけ失敗」と実態に沿った文面を出せる（#806）。
class ProfileUpdatePartialException implements Exception {
  /// 成功したステップまでを反映した最新のユーザー。
  final User user;

  /// 失敗した後続ステップ。`'avatar_remove'` / `'header_remove'`。
  final List<String> failedSteps;

  /// 最初に失敗したステップの元例外（観測用）。
  final Object cause;

  /// [cause] のスタックトレース。
  final StackTrace stackTrace;

  ProfileUpdatePartialException({
    required this.user,
    required this.failedSteps,
    required this.cause,
    required this.stackTrace,
  });

  bool get avatarRemoveFailed => failedSteps.contains('avatar_remove');
  bool get headerRemoveFailed => failedSteps.contains('header_remove');

  @override
  String toString() =>
      'ProfileUpdatePartialException(failedSteps: $failedSteps, cause: $cause)';
}

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
