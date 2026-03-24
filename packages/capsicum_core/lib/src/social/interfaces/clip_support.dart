import '../../model/clip.dart' show NoteClip;
import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class ClipSupport {
  Future<List<NoteClip>> getClips();
  Future<List<Post>> getClipNotes(
    String clipId, {
    TimelineQuery? query,
  });
}
