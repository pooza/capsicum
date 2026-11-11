import '../../model/clip.dart' show ClipDraft, NoteClip;
import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class ClipSupport {
  Future<List<NoteClip>> getClips();
  Future<List<Post>> getClipNotes(String clipId, {TimelineQuery? query});
}

/// クリップを作る・変える・消す、投稿を入れる・外す (#1050)。
///
/// 型はアンテナ（#1052・`AntennaManagementSupport`）と同じ。
abstract mixin class ClipManagementSupport {
  Future<NoteClip> createClip(ClipDraft draft);
  Future<void> updateClip(String clipId, ClipDraft draft);

  /// ⚠ 既に消えていても成功として扱う（消すという目的は果たしている）。
  Future<void> deleteClip(String clipId);

  /// [noteId] を [clipId] に入れる。既に入っていたら [AlreadyClipped]。
  Future<void> addNoteToClip(String clipId, String noteId);
  Future<void> removeNoteFromClip(String clipId, String noteId);

  /// [noteId] が入っている**公開の**クリップの id（ほかの人のものも含む）。
  /// 自分のものは、呼ぶ側が [ClipSupport.getClips] と突き合わせて選ぶ。
  ///
  /// ⚠⚠ **非公開のクリップは分からない。**Misskey の `notes/clips` は公開の
  /// クリップしか返さない。ここに無いことは「入っていない」を意味しない。
  Future<Set<String>> getPublicClipIdsContaining(String noteId);
}

/// これ以上クリップを作れない (#1050)。ロールの `clipLimit` に当たった。
class ClipLimitReached implements Exception {
  const ClipLimitReached();
}

/// このクリップには、これ以上投稿を入れられない (#1050)。ロールの
/// `noteEachClipsLimit` に当たった。
class ClipNoteLimitReached implements Exception {
  const ClipNoteLimitReached();
}

/// 操作しようとしたクリップが、もうサーバーに無い (#1050)。一覧を取ったあとに
/// Web などで消された。⚠ 利用者の操作で起きる状態なので、失敗として Sentry へ
/// 送らない（アンテナの `AntennaNotFound` と同じ）。
class ClipNotFound implements Exception {
  const ClipNotFound();
}

/// その投稿はもうクリップに入っている (#1050)。Web と同じく、外すかを尋ねる
/// きっかけに使う。
class AlreadyClipped implements Exception {
  const AlreadyClipped();
}
