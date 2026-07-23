import 'attachment.dart';
import 'post.dart';
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

  /// リプライ先の投稿 (#833)。Misskey の `notes/drafts/list` が返す `reply`
  /// 埋め込み（`replyId` に対応する Note）から復元する。追加リクエストなしに
  /// compose の `replyTo` へ流せるよう、Post として保持する。元投稿が削除済み等
  /// で埋め込みが無ければ null。
  final Post? reply;

  /// 引用先の投稿 (#833)。Misskey の `renote` 埋め込み（`renoteId` に対応する
  /// Note）から復元する。下書きは本文を持つため renote は実質「引用」を意味する。
  final Post? renote;

  /// チャンネル下書きの復元用 (#833)。`channelId` は常に、`channelName` は
  /// `channel` 埋め込みがある場合に持つ。compose のチャンネル文脈へ流す。
  final String? channelId;
  final String? channelName;

  const Draft({
    required this.id,
    this.content,
    this.spoilerText,
    this.scope = PostScope.public,
    this.attachments = const [],
    required this.createdAt,
    this.reply,
    this.renote,
    this.channelId,
    this.channelName,
  });
}
