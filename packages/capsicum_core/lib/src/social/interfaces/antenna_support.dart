import '../../model/antenna.dart';
import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class AntennaSupport {
  Future<List<Antenna>> getAntennas();
  Future<List<Post>> getAntennaNotes(String antennaId, {TimelineQuery? query});
}
