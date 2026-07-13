import 'attachment.dart';
import 'post_scope.dart';

/// サーバーに保存された下書き 1 件 (#174)。予約投稿（[ScheduledPost]）と同じ
/// Misskey `NoteDraft` を源とするが、`scheduledAt` を持たない「素の下書き」を表す。
/// 予約投稿は時刻で自動投稿される一方、下書きはユーザーが任意に呼び戻して編集・
/// 投稿する点で用途が異なるため、別モデルにしている。
class Draft {
  final String id;
  final String? content;
  final String? spoilerText;
  final PostScope scope;
  final List<Attachment> attachments;
  final DateTime createdAt;

  const Draft({
    required this.id,
    this.content,
    this.spoilerText,
    this.scope = PostScope.public,
    this.attachments = const [],
    required this.createdAt,
  });
}
