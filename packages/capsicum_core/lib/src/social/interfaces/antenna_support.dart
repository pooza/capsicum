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
