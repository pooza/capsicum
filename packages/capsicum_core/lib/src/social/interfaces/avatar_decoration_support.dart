import '../../model/user.dart';

/// サーバーが用意しているアイコンデコレーションの 1 つ (#1349)。
class AvatarDecorationOption {
  final String id;
  final String name;
  final String? description;
  final String url;

  const AvatarDecorationOption({
    required this.id,
    required this.name,
    required this.url,
    this.description,
  });
}

/// 付けたつもりのデコレーションが、サーバーに落とされた (#1349)。
///
/// ⚠ 権限のないものはエラーにならず黙って捨てられるので、保存の応答で確かめた
/// 結果として投げる。
class AvatarDecorationRejected implements Exception {
  const AvatarDecorationRejected();
}

/// これ以上付けられない (#1349)。先にどれかを外す必要がある。
class AvatarDecorationLimitReached implements Exception {
  const AvatarDecorationLimitReached(this.limit);

  final int limit;
}

/// アイコンデコレーションの付け外し (#1349)。
///
/// ⚠⚠ **位置・角度・反転はここでは変えない。**付けたままにするものは今の値を
/// 添えて送るので、Web で調整した位置は崩れない。
abstract mixin class AvatarDecorationSupport {
  Future<List<AvatarDecorationOption>> getAvatarDecorationOptions();

  /// [id] を付ける。付けられる数が 1 つのサーバーでは、今のものと入れ替える。
  Future<User> attachAvatarDecoration(String id);

  /// [id] を外す。
  Future<User> detachAvatarDecoration(String id);
}
