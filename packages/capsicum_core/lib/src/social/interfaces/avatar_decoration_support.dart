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
///
/// [user] はサーバーの今の状態。⚠ 入れ替えのために外したものは付け直してあるが、
/// 呼び出し側はこれで手元の値を揃えること（付け直しが部分的に落ちることもある）。
class AvatarDecorationRejected implements Exception {
  const AvatarDecorationRejected(this.user);

  final User user;
}

/// これ以上付けられない (#1349)。先にどれかを外す必要がある。
class AvatarDecorationLimitReached implements Exception {
  const AvatarDecorationLimitReached(this.limit);

  final int limit;
}

/// アイコンデコレーションの付け外しと調整 (#1349 / #1359)。
///
/// ⚠⚠ **付け外しでは位置・角度・反転を変えない。**付けたままにするものは今の
/// 値を添えて送るので、Web で調整した位置は崩れない。変えるのは
/// [adjustAvatarDecoration] だけ。
abstract mixin class AvatarDecorationSupport {
  Future<List<AvatarDecorationOption>> getAvatarDecorationOptions();

  /// 付けられる数の上限 (#1359)。読めなければ null。
  Future<int?> getAvatarDecorationLimit();

  /// [id] を付ける。付けられる数が 1 つのサーバーでは、今のものと入れ替える。
  Future<User> attachAvatarDecoration(String id);

  /// [id] を外す。
  Future<User> detachAvatarDecoration(String id);

  /// 付けている [id] の位置・角度・反転を変える (#1359)。ほかのデコレーションは
  /// 今の値のまま。値の範囲は Misskey の `i/update` に合わせて丸める
  /// （[angle] -0.5〜0.5・[offsetX] / [offsetY] -0.25〜0.25）。
  ///
  /// サーバー側で既に外れていたら、保存せずに今の状態を返す（呼び出し側は
  /// 戻り値に [id] があるかで見分ける）。
  Future<User> adjustAvatarDecoration(
    String id, {
    required double angle,
    required bool flipH,
    required double offsetX,
    required double offsetY,
  });
}
