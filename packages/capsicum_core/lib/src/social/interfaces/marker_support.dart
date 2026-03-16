class Marker {
  final String lastReadId;
  final int version;
  final DateTime updatedAt;

  const Marker({
    required this.lastReadId,
    required this.version,
    required this.updatedAt,
  });
}

class MarkerSet {
  final Marker? home;
  final Marker? notifications;

  const MarkerSet({this.home, this.notifications});
}

abstract mixin class MarkerSupport {
  Future<MarkerSet> getMarkers();
  Future<void> saveHomeMarker(String lastReadId);
  Future<void> saveNotificationMarker(String lastReadId);
}
