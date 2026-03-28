import 'attachment.dart';
import 'user.dart';

class GalleryPost {
  final String id;
  final String title;
  final String? description;
  final User author;
  final List<Attachment> files;
  final DateTime createdAt;
  final bool isSensitive;
  final int likedCount;

  const GalleryPost({
    required this.id,
    required this.title,
    this.description,
    required this.author,
    required this.files,
    required this.createdAt,
    this.isSensitive = false,
    this.likedCount = 0,
  });
}
