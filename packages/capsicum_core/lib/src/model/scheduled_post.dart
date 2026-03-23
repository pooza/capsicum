/// A post scheduled for future publication.
class ScheduledPost {
  final String id;
  final DateTime scheduledAt;
  final String? content;
  final String? spoilerText;
  final String? visibility;
  final List<String> mediaIds;

  const ScheduledPost({
    required this.id,
    required this.scheduledAt,
    this.content,
    this.spoilerText,
    this.visibility,
    this.mediaIds = const [],
  });
}
