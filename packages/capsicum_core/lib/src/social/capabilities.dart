import '../model/post_scope.dart';
import '../model/timeline_type.dart';

enum Formatting { plainText, markdown, html, mfm }

abstract class AdapterCapabilities {
  Set<PostScope> get supportedScopes;
  Set<Formatting> get supportedFormattings;
  Set<TimelineType> get supportedTimelines;
  int? get maxPostContentLength;
}
