import '../../model/antenna.dart';
import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class AntennaSupport {
  Future<List<Antenna>> getAntennas();
  Future<List<Post>> getAntennaNotes(String antennaId, {TimelineQuery? query});
}

/// アンテナを作る・変える・消す (#1052)。
abstract mixin class AntennaManagementSupport {
  Future<void> createAntenna(AntennaDraft draft);
  Future<void> updateAntenna(String antennaId, AntennaDraft draft);
  Future<void> deleteAntenna(String antennaId);
}

/// これ以上アンテナを作れない (#1052)。ロールの `antennaLimit` に当たった。
class AntennaLimitReached implements Exception {
  const AntennaLimitReached();
}

/// 編集しようとしたアンテナが、もうサーバーに無い（#1372）。一覧を取ったあとに
/// Web などで消された。⚠ 利用者の操作で起きる状態なので、失敗として Sentry へ
/// 送らない。
class AntennaNotFound implements Exception {
  const AntennaNotFound();
}

/// 受信元に選んだリストが、もうサーバーに無い（#1372）。選んだあとに Web などで
/// 消された。[AntennaNotFound] と同じく Sentry へ送らない。
class AntennaUserListNotFound implements Exception {
  const AntennaUserListNotFound();
}
