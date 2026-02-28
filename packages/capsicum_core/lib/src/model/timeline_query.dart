class TimelineQuery {
  final String? maxId;
  final String? sinceId;
  final String? minId;
  final int? limit;

  const TimelineQuery({this.maxId, this.sinceId, this.minId, this.limit});
}
