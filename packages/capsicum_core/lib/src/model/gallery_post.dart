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

  /// 自分がいいねしているか (#1053)。Misskey は認証付きで引いたときだけ返す。
  /// 分からなければ null（「いいねしていない」とは読まない）。
  final bool? isLiked;

  const GalleryPost({
    required this.id,
    required this.title,
    this.description,
    required this.author,
    required this.files,
    required this.createdAt,
    this.isSensitive = false,
    this.likedCount = 0,
    this.isLiked,
  });
}
