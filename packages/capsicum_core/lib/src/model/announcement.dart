class Announcement {
  final String id;
  final String content;
  final String? title;
  final String? imageUrl;
  final DateTime publishedAt;
  final bool read;

  const Announcement({
    required this.id,
    required this.content,
    this.title,
    this.imageUrl,
    required this.publishedAt,
    this.read = false,
  });

  Announcement copyWith({bool? read}) => Announcement(
        id: id,
        content: content,
        title: title,
        imageUrl: imageUrl,
        publishedAt: publishedAt,
        read: read ?? this.read,
      );
}
